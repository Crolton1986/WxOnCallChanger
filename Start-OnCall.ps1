#Requires -Version 7.4
<#
.SYNOPSIS
Starts the On-Call Manager: the web UI plus the Webex check (interval set in Settings).

.DESCRIPTION
Runs on Windows, Linux and macOS, in or out of a container. Two ways to listen:

  Local (default)  http://localhost:8080, no sign-in. Only this computer can reach it.
  Network          https on all interfaces (default port 8443), "Sign in with Webex" required.
                   Set -PublicUrl to the address people will use, for example
                   https://oncall.example.com:8443. The first start prints a setup code.

Every parameter can also come from an environment variable (ONCALL_LISTEN, ONCALL_PORT,
ONCALL_PUBLIC_URL, ONCALL_DATA), which is how the container image sets them.

Pode is loaded from ./lib/Pode if present, otherwise from your installed modules.
Install it once for your account (no admin) with:
    Install-Module -Name Pode -Scope CurrentUser

Press Ctrl+C to stop when running interactively. The Windows scheduled task runs it with -Service.
#>
[CmdletBinding()]
param(
    [ValidateSet('Local', 'Network')][string]$Listen,
    [int]$Port,
    [string]$PublicUrl,
    [switch]$Service   # Windows scheduled task: no console, run as a Pode daemon
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

if (-not $Listen) { $Listen = if ($env:ONCALL_LISTEN) { $env:ONCALL_LISTEN } else { 'Local' } }
if ($Listen -notin 'Local', 'Network') { throw "ONCALL_LISTEN must be Local or Network, not '$Listen'." }
if (-not $Port) { $Port = if ($env:ONCALL_PORT) { [int]$env:ONCALL_PORT } elseif ($Listen -eq 'Network') { 8443 } else { 8080 } }
if (-not $PublicUrl) { $PublicUrl = if ($env:ONCALL_PUBLIC_URL) { $env:ONCALL_PUBLIC_URL } else { "https://localhost:$Port" } }
$PublicUrl = $PublicUrl.TrimEnd('/')
if ($Listen -eq 'Network' -and $PublicUrl -notmatch '^https://[^/\s]+$') {
    throw "PublicUrl must look like https://host or https://host:port, not '$PublicUrl'."
}

$env:ONCALL_ROOT       = $root
$env:ONCALL_LISTEN     = $Listen
$env:ONCALL_PORT       = $Port
$env:ONCALL_PUBLIC_URL = $PublicUrl
if (-not $env:ONCALL_DATA) { $env:ONCALL_DATA = Join-Path $root 'data' }
$verFile = Join-Path $root 'VERSION'
$env:ONCALL_VERSION = if (Test-Path $verFile) { (Get-Content $verFile -Raw).Trim() } else { 'dev' }

# --- Pode -------------------------------------------------------------------
$localPode = Get-ChildItem -Path (Join-Path $root 'lib' 'Pode') -Filter 'Pode.psd1' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($localPode) { Import-Module $localPode.FullName -Force }
elseif (Get-Module -ListAvailable Pode) { Import-Module Pode -Force }
else { throw 'Pode not found. Run: Install-Module -Name Pode -Scope CurrentUser' }

# --- App modules ------------------------------------------------------------
$modules = 'Webex', 'Schedule', 'Auth', 'Web' | ForEach-Object { Join-Path $root 'modules' "$_.psm1" }
$modules | ForEach-Object { Import-Module $_ -Force }

# Fail now, not on the first request, if keys can't be protected or the time zone is unknown.
Initialize-WebexModule -DataPath $env:ONCALL_DATA
$env:ONCALL_DATA = (Resolve-Path -LiteralPath $env:ONCALL_DATA).Path
$protection = Get-OnCallKeyProtection
Initialize-ScheduleModule -DataPath $env:ONCALL_DATA
$tz = Get-ScheduleTimeZone

# Saved keys that can't be read (wrong master key, other Windows account) don't stop the
# server, so they can be re-entered from the web page, but say so up front.
foreach ($name in 'secrets', 'login') {
    try { $null = Read-OnCallSecretFile -Name $name } catch { Write-Warning $_.Exception.Message }
}

$cert = $null
if ($Listen -eq 'Network') {
    $publicHost = ([uri]$PublicUrl).Host
    $cert = Get-OnCallCertificate -DataPath $env:ONCALL_DATA -PublicHost $publicHost
    $env:ONCALL_ALLOWED_HOSTS = (@('localhost', '127.0.0.1', $publicHost) | Select-Object -Unique) -join ','

    # Until sign-in is set up, a one-time code printed here unlocks /setup.
    $env:ONCALL_SETUP_CODE = if (Test-OnCallLoginReady) { '' } else { New-OnCallSetupCode }
}
else {
    $env:ONCALL_ALLOWED_HOSTS = 'localhost,127.0.0.1'
    $env:ONCALL_SETUP_CODE = ''
}

$podeOptions = @{ Threads = 4 }
if ($Service) {
    if (-not $IsWindows) { throw '-Service is for the Windows scheduled task. On Linux, systemd or Docker runs it in the foreground.' }
    $podeOptions.Daemon = $true
}

Start-PodeServer @podeOptions -ScriptBlock {
    # Script variables don't reach this block reliably (see CLAUDE.md), so look things up again.
    $protection = Get-OnCallKeyProtection
    $tz = Get-ScheduleTimeZone
    if ($env:ONCALL_LISTEN -eq 'Network') {
        $cert = Get-OnCallCertificate -DataPath $env:ONCALL_DATA -PublicHost ([uri]$env:ONCALL_PUBLIC_URL).Host
        Add-PodeEndpoint -Address * -Port $env:ONCALL_PORT -Protocol Https -X509Certificate $cert.Certificate
    }
    else {
        Add-PodeEndpoint -Address localhost -Port $env:ONCALL_PORT -Protocol Http
    }

    New-PodeLogFileMethod -Name 'server' -Path (Join-Path $env:ONCALL_ROOT 'logs') -MaxDays 30 | Enable-PodeErrorLogging

    foreach ($m in 'Webex', 'Schedule', 'Auth', 'Web') {
        Import-PodeModule -Path (Join-Path $env:ONCALL_ROOT 'modules' "$m.psm1")
    }

    # Shared across request threads: signed-in sessions and the setup-code lockout.
    Set-PodeState -Name 'sessions' -Value ([System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()) | Out-Null
    Set-PodeState -Name 'setup' -Value ([hashtable]::Synchronized(@{ Code = $env:ONCALL_SETUP_CODE; Fails = 0 })) | Out-Null

    # Guard: right Host header (blocks DNS rebinding) and, for anything that changes data,
    # a custom header (blocks cross-site form posts).
    Add-PodeMiddleware -Name 'guard' -ScriptBlock {
        $host_ = "$($WebEvent.Request.Headers['Host'])" -replace ':\d+$', '' -replace '^\[|\]$', ''
        if ($host_ -notin ($env:ONCALL_ALLOWED_HOSTS -split ',')) {
            Set-PodeResponseStatus -Code 403 -NoErrorPage
            return $false
        }
        if ($WebEvent.Method -in 'post', 'put', 'delete' -and ($WebEvent.Path -like '/api/*' -or $WebEvent.Path -like '/auth/*')) {
            if ($WebEvent.Request.Headers['X-OnCall'] -ne '1') {
                Write-PodeJsonResponse -StatusCode 403 -Value @{ error = 'Missing X-OnCall header.' }
                return $false
            }
        }
        if ($env:ONCALL_LISTEN -eq 'Network') {
            Add-PodeHeader -Name 'Strict-Transport-Security' -Value 'max-age=31536000'
        }
        Add-PodeHeader -Name 'X-Content-Type-Options' -Value 'nosniff'
        Add-PodeHeader -Name 'X-Frame-Options' -Value 'DENY'
        Add-PodeHeader -Name 'Referrer-Policy' -Value 'same-origin'
        return $true
    }

    # Sign-in: local mode trusts this computer; network mode needs a Webex session.
    Add-PodeMiddleware -Name 'auth' -ScriptBlock {
        $WebEvent.OnCallUser = $null
        if ($env:ONCALL_LISTEN -ne 'Network') { Set-OnCallActor 'web'; return $true }

        $open = $WebEvent.Path -in '/login', '/setup', '/api/setup', '/favicon.ico' -or
                $WebEvent.Path -like '/auth/*' -or $WebEvent.Path -like '/public/*'
        $sid = Get-OnCallCookieValue -Header $WebEvent.Request.Headers['Cookie'] -Name 'oncall_sid'
        $s   = Get-OnCallSession -Store (Get-PodeState -Name 'sessions') -Id $sid
        if ($s) {
            $WebEvent.OnCallUser = $s
            Set-OnCallActor $s.Email
            return $true
        }
        Set-OnCallActor 'web'
        if ($open) { return $true }
        if ($WebEvent.Path -like '/api/*') {
            Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Signed out. Reload the page to sign in again.' }
        }
        else { Move-PodeResponseUrl -Url '/login' }
        return $false
    }

    # --- Sign-in pages (network mode) --------------------------------------
    Add-PodeRoute -Method Get -Path '/login' -ScriptBlock {
        if ($env:ONCALL_LISTEN -ne 'Network') { Move-PodeResponseUrl -Url '/'; return }
        if ((Get-PodeState -Name 'setup').Code) { Move-PodeResponseUrl -Url '/setup'; return }
        if ($WebEvent.OnCallUser) { Move-PodeResponseUrl -Url '/'; return }
        Write-PodeFileResponse -Path (Join-Path $env:ONCALL_ROOT 'public' 'login.html') -ContentType 'text/html; charset=utf-8'
    }
    Add-PodeRoute -Method Get -Path '/auth/webex' -ScriptBlock {
        try {
            $state = New-OnCallRandomToken 24
            Add-PodeHeader -Name 'Set-Cookie' -Value (New-OnCallCookieHeader -Name 'oncall_state' -Value $state -MaxAgeSeconds 600)
            Move-PodeResponseUrl -Url (Get-OnCallAuthorizeUrl -State $state -RedirectUri "$($env:ONCALL_PUBLIC_URL)/auth/callback")
        }
        catch { Move-PodeResponseUrl -Url "/login?error=$([uri]::EscapeDataString($_.Exception.Message))" }
    }
    Add-PodeRoute -Method Get -Path '/auth/callback' -ScriptBlock {
        $fail = { param($msg) Move-PodeResponseUrl -Url "/login?error=$([uri]::EscapeDataString($msg))" }
        Add-PodeHeader -Name 'Set-Cookie' -Value (New-OnCallCookieHeader -Name 'oncall_state' -MaxAgeSeconds 0)
        $q = $WebEvent.Query
        if ($q['error']) { & $fail "Webex sign-in was cancelled or refused ($($q['error']))."; return }
        $want = Get-OnCallCookieValue -Header $WebEvent.Request.Headers['Cookie'] -Name 'oncall_state'
        if (-not $want -or -not $q['state'] -or $q['state'] -ne $want) { & $fail 'The sign-in link expired. Try again.'; return }
        try {
            $person = Invoke-OnCallLoginExchange -Code $q['code'] -RedirectUri "$($env:ONCALL_PUBLIC_URL)/auth/callback"
            $check  = Lock-PodeObject -Return -ScriptBlock { Test-OnCallLoginAllowed -Person $person }
        }
        catch { & $fail $_.Exception.Message; return }
        if (-not $check.Allowed) {
            Lock-PodeObject -ScriptBlock {
                Write-OnCallAudit -Event 'login_denied' -Actor $check.Email -Detail "$($check.Reason) (org $($person.OrgId))"
            }
            $msg = if ($check.Reason -eq 'wrong_org') { "$($check.Email) isn't in this app's Webex organization." }
                   else { "$($check.Email) isn't on the list of people who can sign in. Ask someone who can to add you on Settings." }
            & $fail $msg; return
        }
        $sid = New-OnCallSession -Store (Get-PodeState -Name 'sessions') -Email $check.Email -Name $person.Name
        Add-PodeHeader -Name 'Set-Cookie' -Value (New-OnCallCookieHeader -Name 'oncall_sid' -Value $sid)
        Lock-PodeObject -ScriptBlock { Write-OnCallAudit -Event 'login' -Actor $check.Email -Detail $person.Name }
        Move-PodeResponseUrl -Url '/'
    }
    Add-PodeRoute -Method Post -Path '/auth/logout' -ScriptBlock {
        $sid = Get-OnCallCookieValue -Header $WebEvent.Request.Headers['Cookie'] -Name 'oncall_sid'
        Remove-OnCallSession -Store (Get-PodeState -Name 'sessions') -Id $sid
        Add-PodeHeader -Name 'Set-Cookie' -Value (New-OnCallCookieHeader -Name 'oncall_sid' -MaxAgeSeconds 0)
        Write-PodeJsonResponse -Value @{ ok = $true }
    }

    # --- One-time setup (network mode, until sign-in works) -----------------
    Add-PodeRoute -Method Get -Path '/setup' -ScriptBlock {
        if (-not (Get-PodeState -Name 'setup').Code) { Set-PodeResponseStatus -Code 404; return }
        Write-PodeFileResponse -Path (Join-Path $env:ONCALL_ROOT 'public' 'setup.html') -ContentType 'text/html; charset=utf-8'
    }
    Add-PodeRoute -Method Get -Path '/api/setup' -ScriptBlock {
        $st = Get-PodeState -Name 'setup'
        if (-not $st.Code) { Write-PodeJsonResponse -StatusCode 404 -Value @{ error = 'Setup is already done.' }; return }
        $c = Get-OnCallConfig
        Write-PodeJsonResponse -Value @{
            redirectUri = "$($env:ONCALL_PUBLIC_URL)/auth/callback"
            orgId       = $c.Webex.OrgId
            locked      = $st.Fails -ge 5
        }
    }
    Add-PodeRoute -Method Post -Path '/api/setup' -ScriptBlock {
        $st = Get-PodeState -Name 'setup'
        if (-not $st.Code) { Write-PodeJsonResponse -StatusCode 404 -Value @{ error = 'Setup is already done.' }; return }
        $d = $WebEvent.Data
        $result = Lock-PodeObject -Return -ScriptBlock {
            if ($st.Fails -ge 5) { return @{ code = 429; error = 'Too many wrong codes. Restart the app to get a new code.' } }
            if (-not (Test-OnCallSetupCode -Given $d.code -Expected $st.Code)) {
                $st.Fails++
                Write-OnCallAudit -Event 'setup_denied' -Detail "Wrong setup code ($($st.Fails) of 5)"
                return @{ code = 403; error = "That setup code is wrong. $(5 - $st.Fails) tries left." }
            }
            try {
                Complete-OnCallSetup -OrgId "$($d.orgId)" -ClientId "$($d.clientId)" -ClientSecret "$($d.clientSecret)" -Email "$($d.email)"
                $st.Code = ''
                @{ code = 200 }
            }
            catch { @{ code = 400; error = $_.Exception.Message } }
        }
        if ($result.code -eq 200) { Write-PodeJsonResponse -Value @{ ok = $true } }
        else { Write-PodeJsonResponse -StatusCode $result.code -Value @{ error = $result.error } }
    }

    # --- Who's signed in ----------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/me' -ScriptBlock {
        $u = $WebEvent.OnCallUser
        Write-PodeJsonResponse -Value @{ listen = $env:ONCALL_LISTEN; email = $u.Email; name = $u.Name }
    }

    Add-PodeStaticRoute -Path '/public' -Source (Join-Path $env:ONCALL_ROOT 'public')
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Write-PodeFileResponse -Path (Join-Path $env:ONCALL_ROOT 'public' 'index.html') -ContentType 'text/html; charset=utf-8'
    }

    # --- Status and sync ----------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/status' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/sync' -ScriptBlock {
        Invoke-OnCallApi -Lock { Invoke-OnCallSync -Actor 'web'; Get-OnCallStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/switch' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            if ($d.teamKey) { Set-OnCallSwitch -TeamKey $d.teamKey -Enabled ([bool]$d.enabled) }
            else            { Set-OnCallSwitch -Global -Enabled ([bool]$d.enabled) }
            Get-OnCallStatus
        }
    }

    # --- People -------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/people' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallPerson) } }
    }
    Add-PodeRoute -Method Post -Path '/api/people' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Add-OnCallPerson -Name $WebEvent.Data.name -Number $WebEvent.Data.number -Teams @($WebEvent.Data.teams | Where-Object { $_ })
        }
    }
    Add-PodeRoute -Method Put -Path '/api/people/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $p = @{ Person = $WebEvent.Parameters['id'] }
            if ($d.name)   { $p.Name   = $d.name }
            if ($d.number) { $p.Number = $d.number }
            if ($d.ContainsKey('teams')) { $p.Teams = [string[]]@($d.teams | Where-Object { $_ }) }
            Set-OnCallPerson @p
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/people/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock { Remove-OnCallPerson -Person $WebEvent.Parameters['id']; @{ ok = $true } }
    }

    # --- Rotations ----------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/rotations' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallTeams | ForEach-Object { Get-OnCallRotation -TeamKey $_.Key }) } }
    }
    Add-PodeRoute -Method Put -Path '/api/rotations/:team' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            Set-OnCallRotation -TeamKey $WebEvent.Parameters['team'] -Members @($d.members) `
                -AnchorStart $d.anchorStart -AnchorPerson $d.anchorPersonId
            Get-OnCallRotation -TeamKey $WebEvent.Parameters['team']
        }
    }

    # --- Calendar events and overrides --------------------------------------
    Add-PodeRoute -Method Get -Path '/api/events' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallEvents -Start $WebEvent.Query['start'] -End $WebEvent.Query['end'] }
    }
    Add-PodeRoute -Method Post -Path '/api/overrides' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            Add-OnCallOverride -TeamKey $d.teamKey -Person $d.personId -Start $d.start -End $d.end -Note $d.note
        }
    }
    Add-PodeRoute -Method Put -Path '/api/overrides/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $p = @{ Id = $WebEvent.Parameters['id'] }
            if ($d.personId) { $p.Person = $d.personId }
            if ($d.start)    { $p.Start  = $d.start }
            if ($d.end)      { $p.End    = $d.end }
            if ($d.ContainsKey('note')) { $p.Note = "$($d.note)" }
            Set-OnCallOverride @p
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/overrides/:id' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Remove-OnCallOverride -Id $WebEvent.Parameters['id'] -WholeSwap:($WebEvent.Query['swap'] -eq '1')
            @{ ok = $true }
        }
    }

    # --- Week swaps ---------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/swap-options' -ScriptBlock {
        Invoke-OnCallApi {
            Get-OnCallSwapOptions -TeamKey $WebEvent.Query['team'] -WeekStart $WebEvent.Query['week'] -WithPerson $WebEvent.Query['person']
        }
    }
    Add-PodeRoute -Method Post -Path '/api/swaps' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $d = $WebEvent.Data
            $null = New-OnCallSwap -TeamKey $d.teamKey -WeekStart $d.weekStart -WithPerson $d.withPersonId -OtherWeekStart $d.otherWeekStart
            @{ ok = $true }
        }
    }

    # --- Teams --------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/teams' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallTeamsView }
    }
    Add-PodeRoute -Method Post -Path '/api/teams' -ScriptBlock {
        Invoke-OnCallApi -Lock { Add-OnCallTeam -DisplayName "$($WebEvent.Data.displayName)" -WebexTeamId "$($WebEvent.Data.webexTeamId)" }
    }
    Add-PodeRoute -Method Put -Path '/api/teams/:key' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Set-OnCallTeam -TeamKey $WebEvent.Parameters['key'] -DisplayName "$($WebEvent.Data.displayName)" -WebexTeamId "$($WebEvent.Data.webexTeamId)"
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/teams/:key' -ScriptBlock {
        Invoke-OnCallApi -Lock { Remove-OnCallTeam -TeamKey $WebEvent.Parameters['key']; @{ ok = $true } }
    }

    # --- Webex credentials (write-only) --------------------------------------
    Add-PodeRoute -Method Get -Path '/api/credentials' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallCredentialStatus }
    }
    Add-PodeRoute -Method Post -Path '/api/credentials' -ScriptBlock {
        Invoke-OnCallApi -Lock { Update-OnCallCredential -Body $WebEvent.Data }
    }
    Add-PodeRoute -Method Get -Path '/api/settings' -ScriptBlock {
        Invoke-OnCallApi { Get-OnCallSettingsView -CurrentUser $WebEvent.OnCallUser.Email }
    }
    Add-PodeRoute -Method Post -Path '/api/settings' -ScriptBlock {
        Invoke-OnCallApi -Lock { Set-OnCallSettings -Body $WebEvent.Data; Get-OnCallSettingsView -CurrentUser $WebEvent.OnCallUser.Email }
    }
    Add-PodeRoute -Method Get -Path '/api/timezones' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallTimeZoneList) } }
    }

    # --- Sign-in list and login Integration (network mode) ------------------
    Add-PodeRoute -Method Post -Path '/api/users' -ScriptBlock {
        Invoke-OnCallApi -Lock { $null = Add-OnCallUser -Email "$($WebEvent.Data.email)"; Get-OnCallSettingsView -CurrentUser $WebEvent.OnCallUser.Email }
    }
    Add-PodeRoute -Method Delete -Path '/api/users/:email' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            $null = Remove-OnCallUser -Email $WebEvent.Parameters['email'] -CurrentUser $WebEvent.OnCallUser.Email
            Get-OnCallSettingsView -CurrentUser $WebEvent.OnCallUser.Email
        }
    }
    Add-PodeRoute -Method Post -Path '/api/login-integration' -ScriptBlock {
        Invoke-OnCallApi -Lock {
            Set-OnCallLoginIntegration -ClientId "$($WebEvent.Data.clientId)" -ClientSecret "$($WebEvent.Data.clientSecret)"
            Write-OnCallAudit -Event 'login_keys_update' -Detail 'Sign-in Integration keys replaced'
            Get-OnCallSettingsView -CurrentUser $WebEvent.OnCallUser.Email
        }
    }

    # --- Audit --------------------------------------------------------------
    Add-PodeRoute -Method Get -Path '/api/audit' -ScriptBlock {
        Invoke-OnCallApi { @{ items = @(Get-OnCallAudit -Last 300) } }
    }

    # --- The check loop -----------------------------------------------------
    # Ticks every minute but only calls Webex on the interval set in Settings,
    # or right when a handoff or cover changes who should be on call.
    Add-PodeSchedule -Name 'sync' -Cron '* * * * *' -OnStart -ScriptBlock {
        Lock-PodeObject -ScriptBlock {
            try { Invoke-OnCallTick -Actor 'scheduler' }
            catch { Write-OnCallAudit -Event 'sync_error' -Detail $_.Exception.Message -Actor 'scheduler' }
        }
    }

    if ($env:ONCALL_LISTEN -eq 'Network') {
        Write-Host "On-Call Manager $env:ONCALL_VERSION running at $env:ONCALL_PUBLIC_URL (port $env:ONCALL_PORT, all interfaces)" -ForegroundColor Green
        Write-Host "  Certificate: $($cert.Kind), $($cert.Path)"
        if ($env:ONCALL_SETUP_CODE) {
            Write-Host ''
            Write-Host "  First-time setup: open $env:ONCALL_PUBLIC_URL/setup and enter this code:" -ForegroundColor Yellow
            Write-Host "      $env:ONCALL_SETUP_CODE" -ForegroundColor Yellow
            Write-Host '  (A new code is made each start until setup is done.)' -ForegroundColor Yellow
            Write-Host ''
        }
    }
    else {
        Write-Host "On-Call Manager $env:ONCALL_VERSION running at http://localhost:$env:ONCALL_PORT" -ForegroundColor Green
    }
    Write-Host "  Keys: $($protection.Description)"
    Write-Host "  Time zone: $($tz.Id)   (Ctrl+C to stop)"
}
