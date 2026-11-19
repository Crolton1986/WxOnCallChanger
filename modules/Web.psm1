#Requires -Version 7.4
# Web.psm1
# Glue between the Pode routes and the Webex/Schedule modules.
# Every API response is a JSON object. Lists are wrapped as { items: [...] }.

function Invoke-OnCallApi {
    <#
    Runs a route body, returns its last output as JSON, and turns errors into
    HTTP 400 { error }. -Lock serializes writes with the scheduler.
    The audit actor (signed-in email, or 'web' in local mode) is set by the auth middleware.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [switch]$Lock
    )
    try {
        $out = @(if ($Lock) { Lock-PodeObject -Return -ScriptBlock $ScriptBlock } else { & $ScriptBlock })
        $result = if ($out.Count -gt 0) { $out[$out.Count - 1] } else { @{ ok = $true } }
        Write-PodeJsonResponse -Value $result -Depth 10
    }
    catch {
        Write-PodeJsonResponse -StatusCode 400 -Value @{ error = $_.Exception.Message }
    }
}

function Format-Wall { param([datetime]$Time) $Time.ToString('yyyy-MM-ddTHH:mm:ss', [cultureinfo]::InvariantCulture) }

function ConvertFrom-ClientTime {
    <# FullCalendar sends ISO strings with an offset, or plain dates. Returns wall-clock in the schedule's zone. #>
    param([Parameter(Mandatory)][string]$Value)
    $dto = [DateTimeOffset]::Parse($Value, [cultureinfo]::InvariantCulture)
    ConvertTo-ScheduleLocal $dto.UtcDateTime
}

function Get-OnCallStatus {
    $data    = Get-ScheduleData
    $runtime = Get-OnCallRuntime
    $plan    = @(Get-OnCallSyncPlan)

    $teams = foreach ($t in $data.Teams) {
        $row  = $plan | Where-Object { $_.TeamKey -eq $t.Key } | Select-Object -First 1
        $a    = Get-OnCallAssignment -TeamKey $t.Key
        $next = if ($a.Source -ne 'None') { Get-OnCallAssignment -TeamKey $t.Key -At $a.EffectiveEnd } else { $null }
        $curP = $data.People | Where-Object { $_.Number -and $_.Number -eq $row.Current } | Select-Object -First 1
        @{
            key           = $t.Key
            displayName   = $t.DisplayName
            color         = [int]$t.Color
            enabled       = [bool]$row.Enabled
            switchOn      = [bool]$data.Switches.Teams[$t.Key]
            current       = $row.Current
            currentPerson = $curP.Name
            person        = $a.PersonName
            desired       = $a.Number
            source        = $a.Source
            note          = $a.Note
            until         = if ($a.Source -ne 'None') { Format-Wall $a.EffectiveEnd } else { $null }
            nextPerson    = $next.PersonName
            action        = $row.Action
            error         = $row.Error
        }
    }

    $token = try { Get-WebexTokenStatus } catch { $null }
    @{
        now           = Format-Wall (ConvertTo-ScheduleLocal ([datetime]::UtcNow))
        globalEnabled = [bool]$data.Switches.Global
        teams         = @($teams)
        lastCheckUtc  = $runtime.LastRunUtc
        checkMinutes  = [int]$data.Settings.CheckMinutes
        token         = if ($token) {
            @{ refreshDaysRemaining = $token.RefreshDaysRemaining; account = $token.Account
               lastRefresh = $token.LastRefreshLocal.ToString('o'); clientIdHint = $token.ClientIdHint }
        } else { @{ error = 'No Webex credentials stored for this account.' } }
    }
}

function Get-OnCallEvents {
    param([Parameter(Mandatory)][string]$Start, [Parameter(Mandatory)][string]$End)
    $from = ConvertFrom-ClientTime $Start
    $to   = ConvertFrom-ClientTime $End
    $events = foreach ($t in (Get-OnCallTeams)) {
        foreach ($s in (Get-OnCallSlots -TeamKey $t.Key -From $from -To $to)) {
            $isO = $s.Source -eq 'Override'
            @{
                id         = if ($isO) { "o-$($s.OverrideId)" } else { "r-$($t.Key)-$(Format-Wall $s.Start)" }
                title      = if ($s.Note) { "$($s.PersonName) ($($s.Note))" } else { $s.PersonName }
                start      = Format-Wall $s.Start
                end        = Format-Wall $s.End
                editable   = $isO
                classNames = @("tc-$([int]$t.Color)", "src-$($s.Source.ToLower())")
                extendedProps = @{
                    teamKey    = $t.Key
                    teamName   = $t.DisplayName
                    source     = $s.Source
                    overrideId = $s.OverrideId
                    swapId     = $s.SwapId
                    personId   = $s.PersonId
                    personName = $s.PersonName
                    note       = $s.Note
                    priority   = $s.Priority
                }
            }
        }
    }
    @{ items = @($events) }
}

function Get-OnCallCredentialStatus {
    try {
        $t = Get-WebexTokenStatus
        @{
            saved = $true; account = $t.Account; clientIdHint = $t.ClientIdHint
            refreshDaysRemaining = $t.RefreshDaysRemaining
            lastRefresh = $t.LastRefreshLocal.ToString('o')
            runningAs = Get-OnCallAccountName
            checkMinutes = Get-OnCallCheckMinutes
            version = $env:ONCALL_VERSION
        }
    }
    catch { @{ saved = $false; runningAs = Get-OnCallAccountName; error = $_.Exception.Message; checkMinutes = Get-OnCallCheckMinutes; version = $env:ONCALL_VERSION } }
}

function Update-OnCallCredential {
    param([hashtable]$Body)
    $p = @{}
    if ("$($Body.clientId)".Trim())     { $p.ClientId     = "$($Body.clientId)".Trim() }
    if ("$($Body.clientSecret)".Trim()) { $p.ClientSecret = ConvertTo-SecureString "$($Body.clientSecret)".Trim() -AsPlainText -Force }
    if ("$($Body.refreshToken)".Trim()) { $p.RefreshToken = ConvertTo-SecureString "$($Body.refreshToken)".Trim() -AsPlainText -Force }
    if (-not $p.Count) { throw 'Paste at least a new refresh token.' }
    $null = Set-WebexCredential @p -WarningAction SilentlyContinue
    $changed = @($p.Keys | ForEach-Object { @{ ClientId = 'client ID'; ClientSecret = 'client secret'; RefreshToken = 'refresh token' }[$_] }) -join ', '
    Write-OnCallAudit -Event 'credentials_update' -Detail "Updated $changed and tested OK"
    Get-OnCallCredentialStatus
}

function Get-OnCallTeamsView {
    <# Teams with how many people are on each, and what Webex has for them right now. #>
    $data = Get-ScheduleData
    @{ items = @(foreach ($t in $data.Teams) {
        $wx = $null; $err = $null
        try { $wx = Get-WebexTeam -TeamId $t.WebexTeamId } catch { $err = $_.Exception.Message }
        @{
            key         = $t.Key
            displayName = $t.DisplayName
            webexTeamId = $t.WebexTeamId
            color       = [int]$t.Color
            members     = @($data.People | Where-Object { @($_.Teams) -contains $t.Key }).Count
            inRotation  = @($data.Rotations[$t.Key].Members | Where-Object { $_ }).Count
            webexName   = $wx.Name
            current     = $wx.DialedNumber
            error       = $err
        }
    }) }
}


function Get-OnCallSettingsView {
    <# Everything the Settings page shows apart from the Webex keys. #>
    param([string]$CurrentUser)
    $cfg  = Get-OnCallConfig
    $prot = try { (Get-OnCallKeyProtection).Description } catch { $_.Exception.Message }
    $network = $env:ONCALL_LISTEN -eq 'Network'
    $v = @{
        checkMinutes  = Get-OnCallCheckMinutes
        orgId         = $cfg.Webex.OrgId
        configBaseUrl = $cfg.Webex.ConfigBaseUrl
        timeZone      = $cfg.TimeZone
        timeZoneInUse = (Get-ScheduleTimeZone).Id
        hostTimeZone  = [TimeZoneInfo]::Local.Id
        listen        = if ($network) { 'Network' } else { 'Local' }
        publicUrl     = $env:ONCALL_PUBLIC_URL
        protection    = $prot
        runningAs     = Get-OnCallAccountName
        platform      = if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } else { 'Linux' }
        container     = [bool]($env:ONCALL_REQUIRE_MASTER_KEY -eq '1')
        version       = $env:ONCALL_VERSION
        me            = $CurrentUser
    }
    if ($network) {
        $v.login = Get-OnCallLoginStatus -RedirectUri "$($env:ONCALL_PUBLIC_URL)/auth/callback"
        $v.users = @(Get-OnCallUser | ForEach-Object { @{ email = $_.Email; addedBy = $_.AddedBy; addedUtc = $_.AddedUtc } })
    }
    $v
}

function Set-OnCallSettings {
    <# Saves whichever settings are in the request body. #>
    param([hashtable]$Body)
    if ($Body.ContainsKey('checkMinutes')) { Set-OnCallCheckMinutes -Minutes ([int]$Body.checkMinutes) }
    $p = @{}
    foreach ($k in 'orgId', 'configBaseUrl', 'timeZone') { if ($Body.ContainsKey($k)) { $p[$k] = "$($Body[$k])" } }
    if ($p.Count) {
        $before = Get-OnCallConfig
        $old = @{ orgId = $before.Webex.OrgId; configBaseUrl = $before.Webex.ConfigBaseUrl; timeZone = $before.TimeZone }
        $null = Set-OnCallConfig @p
        $after = Get-OnCallConfig
        $new = @{ orgId = $after.Webex.OrgId; configBaseUrl = $after.Webex.ConfigBaseUrl; timeZone = $after.TimeZone }
        $changed = @($p.Keys | Where-Object { $old[$_] -ne $new[$_] } | ForEach-Object { "$_ '$($old[$_])' to '$($new[$_])'" })
        if ($changed.Count) { Write-OnCallAudit -Event 'settings_update' -Detail ($changed -join ', ') }
    }
}

function Get-OnCallTimeZoneList {
    <# Zones for the Settings picker, in the platform's own IDs. #>
    @([TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { @{ id = $_.Id; name = $_.DisplayName } })
}

function Get-OnCallCertificate {
    <#
    The HTTPS certificate for network mode:
      1. ONCALL_CERT_FILE + ONCALL_KEY_FILE (PEM), or a .pfx/.p12 in ONCALL_CERT_FILE with
         ONCALL_CERT_PASSWORD. Defaults: data/tls/cert.pem + data/tls/key.pem.
      2. None there: make a self-signed one in data/tls/ (and remake it if the host changes).
    Returned through a PKCS#12 round trip, since Windows TLS can't use a key loaded from PEM.
    #>
    param([Parameter(Mandatory)][string]$DataPath, [Parameter(Mandatory)][string]$PublicHost)
    $tls    = Join-Path $DataPath 'tls'
    $cert   = if ($env:ONCALL_CERT_FILE) { $env:ONCALL_CERT_FILE } else { Join-Path $tls 'cert.pem' }
    $key    = if ($env:ONCALL_KEY_FILE)  { $env:ONCALL_KEY_FILE }  else { Join-Path $tls 'key.pem' }
    $marker = Join-Path $tls 'self-signed.txt'
    $hosts  = @($PublicHost, 'localhost') | Where-Object { $_ } | Select-Object -Unique
    $X509   = [System.Security.Cryptography.X509Certificates.X509Certificate2]

    # A cert we made ourselves is remade when the host name changes. The marker holds the
    # hosts and thumbprint, so a cert you drop in at the same path is never overwritten.
    $c = $null
    if (Test-Path -LiteralPath $cert) {
        $c = if ($cert -match '\.(pfx|p12)$') { $X509::new($cert, $env:ONCALL_CERT_PASSWORD) }
             else {
                 if (-not (Test-Path -LiteralPath $key)) { throw "Certificate $cert has no key file at $key. Set ONCALL_KEY_FILE." }
                 $X509::CreateFromPemFile($cert, $key)
             }
    }
    $mark = if (Test-Path -LiteralPath $marker) { (Get-Content -LiteralPath $marker -Raw).Trim() } else { '' }
    $selfMade = $c -and $mark -like "*|$($c.Thumbprint)"
    $stale    = $selfMade -and $mark -ne "$($hosts -join ',')|$($c.Thumbprint)"
    if ($c -and -not $stale) {
        $kind = if ($selfMade) { 'self-signed' } else { 'provided' }
    }
    else {
        if ($env:ONCALL_CERT_FILE) { throw "ONCALL_CERT_FILE is set to '$cert', which doesn't exist." }
        if (-not (Test-Path -LiteralPath $tls)) { $null = New-Item -ItemType Directory -Path $tls -Force }
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                   "CN=$($hosts[0])", $rsa, [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                   [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $san = [System.Security.Cryptography.X509Certificates.SubjectAlternativeNameBuilder]::new()
        foreach ($h in $hosts) {
            $ip = $null
            if ([System.Net.IPAddress]::TryParse($h, [ref]$ip)) { $san.AddIpAddress($ip) } else { $san.AddDnsName($h) }
        }
        $san.AddIpAddress([System.Net.IPAddress]::Loopback)
        $req.CertificateExtensions.Add($san.Build())
        $eku = [System.Security.Cryptography.OidCollection]::new()
        $null = $eku.Add([System.Security.Cryptography.Oid]::new('1.3.6.1.5.5.7.3.1'))
        $req.CertificateExtensions.Add([System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]::new($eku, $false))
        $c = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(2))
        Set-Content -LiteralPath $cert -Value $c.ExportCertificatePem() -Encoding ascii
        Write-OnCallPrivateFile -Path $key -Bytes ([Text.Encoding]::ASCII.GetBytes($rsa.ExportPkcs8PrivateKeyPem()))
        Set-Content -LiteralPath $marker -Value "$($hosts -join ',')|$($c.Thumbprint)" -Encoding ascii
        $kind = 'self-signed (new)'
    }
    $pfx = $c.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12)
    [pscustomobject]@{
        Certificate = $X509::new($pfx, [string]$null, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
        Kind        = $kind
        Path        = $cert
    }
}

Export-ModuleMember -Function Get-OnCallSettingsView, Set-OnCallSettings, Get-OnCallTimeZoneList, Get-OnCallCertificate,
    Get-OnCallTeamsView, Get-OnCallCredentialStatus, Update-OnCallCredential, Invoke-OnCallApi, Get-OnCallStatus, Get-OnCallEvents, ConvertFrom-ClientTime
