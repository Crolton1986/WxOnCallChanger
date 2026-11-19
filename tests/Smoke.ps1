#Requires -Version 7.4
<#
.SYNOPSIS
End-to-end smoke test against tests/mock_webex.py. Runs on Windows, Linux and macOS.

.DESCRIPTION
Starts the real server twice, in a throwaway data folder each time:
  Local   - http://localhost, no sign-in: save Webex keys, add a team and a person, sync, guards.
  Network - https with a self-signed cert: setup code, Webex sign-in through the mock,
            refused sign-ins, the sign-in list, sign-out.
Needs the mock running first:  python tests/mock_webex.py
Exits non-zero on the first failure.
#>
[CmdletBinding()]
param(
    [string]$MockUrl = 'http://127.0.0.1:8765',
    [int]$LocalPort = 18080,
    [int]$NetworkPort = 18443
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$org  = '11111111-2222-3333-4444-555555555555'
$work = Join-Path ([IO.Path]::GetTempPath()) "oncall-smoke-$([guid]::NewGuid().ToString('n').Substring(0, 8))"
$null = New-Item -ItemType Directory -Path $work
if (-not $IsWindows) { $env:XDG_CONFIG_HOME = Join-Path $work 'xdg' }   # keep the generated master key out of ~/.config

function Show-Check { param([bool]$Ok, [string]$What) if (-not $Ok) { throw "FAIL: $What" }; Write-Host "  ok  $What" }

function Invoke-Http {
    param([string]$Uri, [string]$Method = 'GET', $Body, [hashtable]$Headers = @{}, $Session, [switch]$NoGuardHeader)
    $h = @{} + $Headers
    if ($Method -ne 'GET' -and -not $NoGuardHeader) { $h['X-OnCall'] = '1' }
    $p = @{ Uri = $Uri; Method = $Method; Headers = $h; SkipHttpErrorCheck = $true; SkipCertificateCheck = $true
            MaximumRedirection = 0; TimeoutSec = 30; NoProxy = $true; AllowInsecureRedirect = $true }
    if ($Session) { $p.WebSession = $Session }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Compress); $p.ContentType = 'application/json' }
    # With MaximumRedirection 0, a 302 still comes back but also raises a non-terminating error.
    $ev = $null
    $r = Invoke-WebRequest @p -ErrorAction SilentlyContinue -ErrorVariable ev
    if (-not $r) { throw $ev[0] }
    $r
}

function Get-Json { param($Resp) $Resp.Content | ConvertFrom-Json -AsHashtable }

function Start-App {
    param([string]$Listen, [int]$Port, [string]$Name)
    $data = Join-Path $work $Name
    $null = New-Item -ItemType Directory -Path $data
    @{ Webex = @{ TokenUrl = "$MockUrl/v1/access_token"; ConfigBaseUrl = $MockUrl; AuthBaseUrl = $MockUrl; OrgId = $org }
       TimeZone = 'America/Los_Angeles' } | ConvertTo-Json | Set-Content (Join-Path $data 'config.json')
    $env:ONCALL_DATA = $data
    $log = Join-Path $work "$Name.log"
    $proc = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -RedirectStandardOutput $log `
        -RedirectStandardError "$log.err" -ArgumentList @(
            '-NoProfile', '-File', (Join-Path $root 'Start-OnCall.ps1'), '-Listen', $Listen, '-Port', $Port)
    $base = if ($Listen -eq 'Network') { "https://localhost:$Port" } else { "http://localhost:$Port" }
    for ($i = 0; $i -lt 60; $i++) {
        try { $null = Invoke-Http "$base/login"; break } catch { Start-Sleep -Seconds 1 }
    }
    if ($i -ge 60) { Get-Content $log, "$log.err" -ErrorAction SilentlyContinue; throw "Server ($Listen) didn't start." }
    [pscustomobject]@{ Process = $proc; Base = $base; Data = $data; Log = $log }
}

function Stop-App { param($App) if ($App -and -not $App.Process.HasExited) { Stop-Process -Id $App.Process.Id -Force } }

function Invoke-WebexLogin {
    <# Follows /auth/webex -> mock authorize -> /auth/callback. Returns the callback's redirect target. #>
    param($App, $Session, [string]$Email, [string]$Org = $org)
    $null = Invoke-RestMethod -NoProxy "$MockUrl/mock/user?email=$([uri]::EscapeDataString($Email))&org=$Org&name=Test"
    $r1 = Invoke-Http "$($App.Base)/auth/webex" -Session $Session
    $r2 = Invoke-Http "$($r1.Headers.Location)"
    $r3 = Invoke-Http "$($r2.Headers.Location)" -Session $Session
    "$($r3.Headers.Location)"
}

$local = $null; $net = $null
try {
    # --- Local mode --------------------------------------------------------
    Write-Host "Local mode ($(if ($IsWindows) { 'Windows' } else { 'Unix' }))" -ForegroundColor Cyan
    $local = Start-App -Listen Local -Port $LocalPort -Name 'local'
    $b = $local.Base
    Show-Check ((Invoke-Http "$b/api/status").StatusCode -eq 200) 'status without sign-in'
    $me = Get-Json (Invoke-Http "$b/api/me")
    Show-Check ($me.listen -eq 'Local') 'reports Local mode'

    $r = Invoke-Http "$b/api/credentials" -Method Post -Body @{ clientId = 'Cabc'; clientSecret = 'sec'; refreshToken = 'rt' }
    Show-Check ($r.StatusCode -eq 200 -and (Get-Json $r).saved) 'save and test Webex keys'
    $expect = if ($IsWindows) { 'secrets.clixml' } else { 'secrets.json' }
    Show-Check (Test-Path (Join-Path $local.Data $expect)) "keys stored as $expect"
    $r = Invoke-Http "$b/api/credentials" -Method Post -Body @{ refreshToken = 'expired' }
    Show-Check ($r.StatusCode -eq 400 -and (Get-Json $r).error -like '*previous keys were kept*') 'bad refresh token keeps old keys'

    $team = Get-Json (Invoke-Http "$b/api/teams" -Method Post -Body @{ displayName = 'Support'; webexTeamId = 'aaaaaaaa-0000-4000-8000-000000000001' })
    Show-Check ($team.Key -eq 'support') 'add team'
    $person = Get-Json (Invoke-Http "$b/api/people" -Method Post -Body @{ name = 'Alex Rivera'; number = '555 555 1234'; teams = @('support') })
    Show-Check ($person.Number -eq '15555551234') 'add person'
    $null = Invoke-Http "$b/api/rotations/support" -Method Put -Body @{ members = @($person.Id); anchorStart = '2026-01-05T08:00'; anchorPersonId = $person.Id }
    $null = Invoke-Http "$b/api/switch" -Method Post -Body @{ enabled = $true }
    $null = Invoke-Http "$b/api/switch" -Method Post -Body @{ teamKey = 'support'; enabled = $true }
    $s = Get-Json (Invoke-Http "$b/api/sync" -Method Post -Body @{})
    $row = $s.teams | Where-Object { $_.key -eq 'support' }
    Show-Check ($row.current -eq '15555551234') 'sync switched the team in Webex'
    Show-Check ((Invoke-Http "$b/api/status" -Headers @{ Host = 'evil.example' }).StatusCode -eq 403) 'wrong Host refused'
    Show-Check ((Invoke-Http "$b/api/sync" -Method Post -Body @{} -NoGuardHeader).StatusCode -eq 403) 'write without X-OnCall refused'
    $s = Get-Json (Invoke-Http "$b/api/settings" -Method Post -Body @{ timeZone = 'Europe/London' })
    Show-Check ($s.timeZoneInUse -match 'London|GMT') 'change time zone'
    Stop-App $local; $local = $null

    # --- Network mode ------------------------------------------------------
    Write-Host 'Network mode' -ForegroundColor Cyan
    $net = Start-App -Listen Network -Port $NetworkPort -Name 'network'
    $b = $net.Base
    Show-Check ((Invoke-Http "$b/api/status").StatusCode -eq 401) 'API needs sign-in'
    Show-Check ("$((Invoke-Http "$b/").Headers.Location)" -like '*/login') 'page redirects to /login'
    Show-Check ("$((Invoke-Http "$b/login").Headers.Location)" -like '*/setup') 'login sends to setup first'
    Show-Check (Test-Path (Join-Path $net.Data 'tls' 'cert.pem')) 'self-signed cert created'

    $code = (Select-String -Path $net.Log -Pattern '^\s+([A-Z2-9]{8})\s*$' | Select-Object -First 1).Matches[0].Groups[1].Value
    Show-Check ([bool]$code) 'setup code printed'
    $clientId = 'C' + ('a' * 64)
    $r = Invoke-Http "$b/api/setup" -Method Post -Body @{ code = 'WRONG123'; orgId = $org; clientId = $clientId; clientSecret = 's'; email = 'admin@example.com' }
    Show-Check ($r.StatusCode -eq 403) 'wrong setup code refused'
    $r = Invoke-Http "$b/api/setup" -Method Post -Body @{ code = $code; orgId = $org; clientId = $clientId; clientSecret = 's'; email = 'Admin@Example.com' }
    Show-Check ($r.StatusCode -eq 200) 'setup with the right code'
    Show-Check ((Invoke-Http "$b/setup").StatusCode -eq 404) 'setup closed afterwards'

    $ws = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    Show-Check ((Invoke-WebexLogin -App $net -Session $ws -Email 'admin@example.com') -eq '/') 'listed user signs in'
    $me = Get-Json (Invoke-Http "$b/api/me" -Session $ws)
    Show-Check ($me.email -eq 'admin@example.com') 'session knows who signed in'
    Show-Check ((Invoke-Http "$b/api/status" -Session $ws).StatusCode -eq 200) 'API works when signed in'

    $other = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
    Show-Check ((Invoke-WebexLogin -App $net -Session $other -Email 'bob@example.com') -like '/login?error=*list*') 'unlisted user refused'
    Show-Check ((Invoke-WebexLogin -App $net -Session $other -Email 'admin@example.com' -Org '99999999-2222-3333-4444-555555555555') -like '/login?error=*organization*') 'other org refused'

    $s = Get-Json (Invoke-Http "$b/api/users" -Method Post -Body @{ email = 'bob@example.com' } -Session $ws)
    Show-Check (@($s.users).Count -eq 2) 'add someone to the sign-in list'
    Show-Check ((Invoke-WebexLogin -App $net -Session $other -Email 'bob@example.com') -eq '/') 'newly listed user signs in'
    $r = Invoke-Http "$b/api/users/admin%40example.com" -Method Delete -Session $ws
    Show-Check ($r.StatusCode -eq 400) "can't remove yourself"
    $null = Invoke-Http "$b/api/users/bob%40example.com" -Method Delete -Session $ws
    Show-Check ((Invoke-Http "$b/api/status" -Session $other).StatusCode -eq 401) 'removed user loses access right away'

    $audit = Get-Content (Join-Path $net.Data 'audit.jsonl') | ConvertFrom-Json
    Show-Check (@($audit | Where-Object { $_.Event -eq 'user_add' -and $_.Actor -eq 'admin@example.com' }).Count -eq 1) 'audit shows who made the change'

    $null = Invoke-Http "$b/auth/logout" -Method Post -Body @{} -Session $ws
    Show-Check ((Invoke-Http "$b/api/status" -Session $ws).StatusCode -eq 401) 'sign-out ends the session'

    Write-Host 'All smoke checks passed.' -ForegroundColor Green
}
catch {
    foreach ($a in $local, $net) {
        if ($a) { Write-Host "--- $($a.Log)"; Get-Content $a.Log, "$($a.Log).err" -ErrorAction SilentlyContinue | Select-Object -Last 40 }
    }
    throw
}
finally {
    Stop-App $local; Stop-App $net
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
