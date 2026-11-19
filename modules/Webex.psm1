#Requires -Version 7.4
# Webex.psm1
# Webex Contact Center config-service client for the On-Call Manager, with Service App auth.
#
# PUT semantics: GET the full team object, change ONLY dialedNumber, PUT the whole object back.
# Uses System.Text.Json so every other field round-trips byte for byte
# (ConvertFrom-Json in PS7 rewrites date strings, which we don't want to PUT back).
#
# Secrets live in data\ and are encrypted one of two ways (see Get-OnCallKeyProtection):
#   - a master key file (AES-256-GCM, data\<name>.json), used when one is configured and on Linux
#   - Windows DPAPI (data\<name>.clixml), readable only by the Windows account that saved it

$script:Config      = $null
$script:ConfigFile  = $null
$script:ConfigStamp = $null
$script:DataDir     = $null
$script:Protection  = $null

$script:DefaultWebex = [ordered]@{
    TokenUrl      = 'https://webexapis.com/v1/access_token'
    AuthBaseUrl   = 'https://webexapis.com'
    ConfigBaseUrl = 'https://api.wxcc-us1.cisco.com'
    OrgId         = ''
}

# ---------------------------------------------------------------------------
# Setup and config
# ---------------------------------------------------------------------------

function Get-OnCallAccountName {
    <# The OS account this process runs as, for display and audit. #>
    if ($IsWindows) { return "$([Environment]::UserDomainName)\$([Environment]::UserName)" }
    [Environment]::UserName
}

function Initialize-WebexModule {
    <# Points the module at a data folder. Creates the folder and a default config.json if missing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataPath)

    if (-not (Test-Path -LiteralPath $DataPath)) { $null = New-Item -ItemType Directory -Path $DataPath -Force }
    $script:DataDir    = (Resolve-Path -LiteralPath $DataPath).Path
    $script:ConfigFile = Join-Path $script:DataDir 'config.json'
    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {
        $w = [ordered]@{}; foreach ($k in $script:DefaultWebex.Keys) { $w[$k] = $script:DefaultWebex[$k] }
        Save-OnCallConfigFile ([ordered]@{ Webex = $w; TimeZone = '' })
    }
    $script:Config = $null
    $null = Get-OnCallConfig
}

function Assert-WebexInit {
    if ($script:DataDir) { return }
    if ($env:ONCALL_DATA) { Initialize-WebexModule -DataPath $env:ONCALL_DATA; return }
    throw 'Run Initialize-WebexModule first.'
}

function Save-OnCallConfigFile {
    param([Parameter(Mandatory)]$Config)
    $tmp = "$($script:ConfigFile).tmp"
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $script:ConfigFile -Force
}

function Get-OnCallConfig {
    <# config.json as a hashtable, with defaults filled in. Re-read whenever the file changes,
       so a change saved from one web request is seen by the others and by the scheduler. #>
    Assert-WebexInit
    $stamp = (Get-Item -LiteralPath $script:ConfigFile).LastWriteTimeUtc
    if (-not $script:Config -or $stamp -ne $script:ConfigStamp) {
        $c = Get-Content -LiteralPath $script:ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $c) { $c = @{} }
        if (-not $c.Webex) { $c.Webex = @{} }
        foreach ($k in $script:DefaultWebex.Keys) {
            if ([string]::IsNullOrWhiteSpace($c.Webex[$k]) -and $k -ne 'OrgId') { $c.Webex[$k] = $script:DefaultWebex[$k] }
            if ($null -eq $c.Webex[$k]) { $c.Webex[$k] = '' }
        }
        if ($null -eq $c.TimeZone) { $c.TimeZone = '' }
        $script:Config      = $c
        $script:ConfigStamp = $stamp
    }
    $script:Config
}

function Set-OnCallConfig {
    <# Changes the org-level settings that live in config.json. Only the values passed change. #>
    [CmdletBinding()]
    param([string]$OrgId, [string]$ConfigBaseUrl, [string]$TimeZone)

    $c = Get-OnCallConfig
    if ($PSBoundParameters.ContainsKey('OrgId')) {
        $g = [guid]::Empty
        $v = "$OrgId".Trim()
        if ($v -and -not [guid]::TryParse($v, [ref]$g)) { throw "'$v' is not an org ID. Use the UUID from Control Hub." }
        $c.Webex.OrgId = if ($v) { $g.ToString() } else { '' }
    }
    if ($PSBoundParameters.ContainsKey('ConfigBaseUrl')) {
        $u = "$ConfigBaseUrl".Trim().TrimEnd('/')
        if ($u -notmatch '^https?://[^/\s]+$') { throw "'$u' is not a base URL like https://api.wxcc-us1.cisco.com" }
        $c.Webex.ConfigBaseUrl = $u
    }
    if ($PSBoundParameters.ContainsKey('TimeZone')) {
        $z = "$TimeZone".Trim()
        if ($z) {
            try { $z = [TimeZoneInfo]::FindSystemTimeZoneById($z).Id }
            catch { throw "Unknown time zone '$z'." }
        }
        $c.TimeZone = $z
    }
    Save-OnCallConfigFile $c
    $script:Config = $null
    Get-OnCallConfig
}

# ---------------------------------------------------------------------------
# Secret store
# ---------------------------------------------------------------------------

function Get-OnCallKeyProtection {
    <#
    Decides how secrets are encrypted at rest:
      1. ONCALL_MASTER_KEY_FILE, or a Docker secret at /run/secrets/oncall_master_key -> AES-GCM
      2. Windows -> DPAPI (only the account that saved the keys can read them)
      3. Anything else -> AES-GCM with a key generated once in the user's config folder,
         outside data\, so copying data\ alone doesn't give away the keys.
    ONCALL_REQUIRE_MASTER_KEY=1 turns step 2 and 3 off (the container image sets it), so a
    missing secret fails loudly instead of quietly using a key that vanishes with the container.
    #>
    if ($script:Protection) { return $script:Protection }

    $file = $env:ONCALL_MASTER_KEY_FILE
    $dockerSecret = '/run/secrets/oncall_master_key'
    if ($file) {
        if (-not (Test-Path -LiteralPath $file)) { throw "ONCALL_MASTER_KEY_FILE is set to '$file', which doesn't exist." }
    }
    elseif (Test-Path -LiteralPath $dockerSecret) { $file = $dockerSecret }
    elseif ($env:ONCALL_REQUIRE_MASTER_KEY -eq '1') {
        throw "No master key found. Mount one as the Docker secret 'oncall_master_key' or set ONCALL_MASTER_KEY_FILE."
    }
    elseif ($IsWindows) {
        $script:Protection = @{ Method = 'Dpapi'; Description = "Windows DPAPI, readable only by $(Get-OnCallAccountName)" }
        return $script:Protection
    }
    else {
        $base = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME '.config' }
        $file = Join-Path (Join-Path $base 'oncall') 'master.key'
        if (-not (Test-Path -LiteralPath $file)) { New-OnCallMasterKeyFile -Path $file }
    }

    $text = (Get-Content -LiteralPath $file -Raw).Trim()
    if ($text.Length -lt 32) { throw "The master key in '$file' is too short. Use at least 32 random characters." }
    $script:Protection = @{
        Method      = 'AesGcm'
        Key         = [System.Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))
        KeyFile     = $file
        Description = "AES-256-GCM with the master key at $file"
    }
    $script:Protection
}

function New-OnCallMasterKeyFile {
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }
    $key = [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(48))
    Write-OnCallPrivateFile -Path $Path -Bytes ([Text.Encoding]::ASCII.GetBytes($key))
}

function Write-OnCallPrivateFile {
    <# Writes a file only its owner can read (on Linux/macOS mode 600 from the moment it exists). #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $opt = [IO.FileStreamOptions]::new()
    $opt.Mode   = [IO.FileMode]::Create
    $opt.Access = [IO.FileAccess]::Write
    if (-not $IsWindows) { $opt.UnixCreateMode = [IO.UnixFileMode]'UserRead, UserWrite' }
    $fs = [IO.FileStream]::new($Path, $opt)
    try { $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($Path, [IO.UnixFileMode]'UserRead, UserWrite') }
}

function Use-WebexSecretLock {
    <#
    Runs a script block while holding a named lock on the data folder's key files, so the web
    page and the scheduler never read or write them at the same time. Re-entrant on one thread.
    #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Assert-WebexInit
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($script:DataDir.ToLowerInvariant()))).Substring(0, 16)
    $m = [System.Threading.Mutex]::new($false, "Local\OnCallManager-$hash")
    $owned = $false
    try {
        try { $owned = $m.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Timed out waiting for the key files.' }
        & $ScriptBlock
    }
    finally {
        if ($owned) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function ConvertTo-SecretJson {
    <# Store hashtable -> JSON text. SecureStrings and DateTimes are tagged so they come back typed. #>
    param([Parameter(Mandatory)][hashtable]$Store)
    $o = [ordered]@{}
    foreach ($k in $Store.Keys) {
        $v = $Store[$k]
        $o[$k] = if ($v -is [securestring]) { @{ '$s' = (ConvertFrom-SecureString $v -AsPlainText) } }
                 elseif ($v -is [datetime]) { @{ '$t' = $v.ToUniversalTime().Ticks } }
                 else { $v }
    }
    $o | ConvertTo-Json -Compress -Depth 5
}

function ConvertFrom-SecretJson {
    param([Parameter(Mandatory)][string]$Json)
    $raw = $Json | ConvertFrom-Json -AsHashtable
    $out = @{}
    foreach ($k in $raw.Keys) {
        $v = $raw[$k]
        $out[$k] = if ($v -is [hashtable] -and $v.ContainsKey('$s')) { ConvertTo-SecureString $v['$s'] -AsPlainText -Force }
                   elseif ($v -is [hashtable] -and $v.ContainsKey('$t')) { [datetime]::new([long]$v['$t'], 'Utc') }
                   else { $v }
    }
    $out
}

function Read-OnCallSecretFile {
    <# Returns the named store (hashtable) or $null when nothing is saved yet. #>
    param([Parameter(Mandatory)][string]$Name)
    Assert-WebexInit
    $prot  = Get-OnCallKeyProtection
    $dpapi = Join-Path $script:DataDir "$Name.clixml"
    $aes   = Join-Path $script:DataDir "$Name.json"
    Use-WebexSecretLock {
        if ($prot.Method -eq 'Dpapi') {
            if (Test-Path -LiteralPath $dpapi) {
                try {
                    $s = Import-Clixml -LiteralPath $dpapi
                    foreach ($v in $s.Values) { if ($v -is [securestring]) { $null = ConvertFrom-SecureString $v -AsPlainText } }
                    return $s
                }
                catch { throw "The saved keys in $Name.clixml belong to a different Windows account. Enter them again on Settings, or run as the account that saved them." }
            }
            if (Test-Path -LiteralPath $aes) {
                throw "The saved keys in $Name.json were encrypted with a master key. Set ONCALL_MASTER_KEY_FILE to that key file, or enter the keys again on Settings."
            }
            return $null
        }

        if (Test-Path -LiteralPath $aes) {
            try {
                $f     = Get-Content -LiteralPath $aes -Raw | ConvertFrom-Json
                $nonce = [Convert]::FromBase64String($f.nonce)
                $tag   = [Convert]::FromBase64String($f.tag)
                $data  = [Convert]::FromBase64String($f.data)
                $plain = [byte[]]::new($data.Length)
                $gcm   = [System.Security.Cryptography.AesGcm]::new($prot.Key, 16)
                try { $gcm.Decrypt($nonce, $data, $tag, $plain, [Text.Encoding]::UTF8.GetBytes("oncall:$Name")) }
                finally { $gcm.Dispose() }
                return ConvertFrom-SecretJson ([Text.Encoding]::UTF8.GetString($plain))
            }
            catch {
                throw "The saved keys in $Name.json can't be decrypted with the master key at $($prot.KeyFile). It's the wrong key, or the file is damaged. Use the original key, or enter the keys again on Settings."
            }
        }
        if (Test-Path -LiteralPath $dpapi) {
            throw "The saved keys in $Name.clixml were protected with Windows DPAPI, which this setup doesn't use. Enter them again on Settings."
        }
        $null
    }
}

function Write-OnCallSecretFile {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][hashtable]$Store)
    Assert-WebexInit
    $prot = Get-OnCallKeyProtection
    Use-WebexSecretLock {
        # Write a temp file and swap it in, so a crash mid-write never leaves a broken keys file.
        if ($prot.Method -eq 'Dpapi') {
            $path = Join-Path $script:DataDir "$Name.clixml"
            $Store | Export-Clixml -LiteralPath "$path.tmp" -Force
        }
        else {
            $path   = Join-Path $script:DataDir "$Name.json"
            $plain  = [Text.Encoding]::UTF8.GetBytes((ConvertTo-SecretJson $Store))
            $nonce  = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
            $cipher = [byte[]]::new($plain.Length)
            $tag    = [byte[]]::new(16)
            $gcm    = [System.Security.Cryptography.AesGcm]::new($prot.Key, 16)
            try { $gcm.Encrypt($nonce, $plain, $cipher, $tag, [Text.Encoding]::UTF8.GetBytes("oncall:$Name")) }
            finally { $gcm.Dispose() }
            $doc = [ordered]@{
                v = 1; alg = 'AES-256-GCM'
                nonce = [Convert]::ToBase64String($nonce); tag = [Convert]::ToBase64String($tag)
                data  = [Convert]::ToBase64String($cipher)
            } | ConvertTo-Json -Compress
            Write-OnCallPrivateFile -Path "$path.tmp" -Bytes ([Text.Encoding]::UTF8.GetBytes($doc))
        }
        Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
    }
}

function Get-WebexSecretStore {
    $s = Read-OnCallSecretFile -Name 'secrets'
    if (-not $s) { throw 'No Webex keys saved yet. Add them on the Settings page.' }
    $s
}

function Save-WebexSecretStore {
    param([Parameter(Mandatory)][hashtable]$Store)
    Write-OnCallSecretFile -Name 'secrets' -Store $Store
}

function Set-WebexCredential {
    <#
    .SYNOPSIS
    Saves the Service App client ID, client secret and refresh token, encrypted to the
    way set by Get-OnCallKeyProtection, then proves them with a token refresh. If the test fails,
    the previous keys are put back.

    With no parameters it prompts for all three. From the web UI, any value left out
    keeps the one already saved (usually you only paste a new refresh token).
    #>
    [CmdletBinding()]
    param(
        [string]$ClientId,
        [securestring]$ClientSecret,
        [securestring]$RefreshToken
    )

    $interactive = -not ($PSBoundParameters.ContainsKey('ClientId') -or
                         $PSBoundParameters.ContainsKey('ClientSecret') -or
                         $PSBoundParameters.ContainsKey('RefreshToken'))
    if ($interactive) {
        Write-Host @'

All three values come from your Service App page in the Webex Developer Portal.
  1. Client ID      : "Authorization" section, Client ID box (starts with C)
  2. Client secret  : click "Regenerate the client secret" and copy it
  3. Refresh token  : paste that secret into "Enter Client Secret" under
                      Org Authorizations, click "Generate tokens", copy the REFRESH token
Do not use the Org ID or the Service App ID.

'@ -ForegroundColor Yellow
        $ClientId     = Read-Host '1. Client ID'
        $ClientSecret = Read-Host '2. Client secret' -AsSecureString
        $RefreshToken = Read-Host '3. Refresh token (from Generate tokens)' -AsSecureString
    }

    $trim = {
        param([securestring]$v)
        if (-not $v -or $v.Length -eq 0) { return $null }
        $t = (ConvertFrom-SecureString $v -AsPlainText).Trim()
        if (-not $t) { return $null }
        ConvertTo-SecureString $t -AsPlainText -Force
    }
    $ClientId     = "$ClientId".Trim()
    $ClientSecret = & $trim $ClientSecret
    $RefreshToken = & $trim $RefreshToken

    Use-WebexSecretLock {
        $old = $null
        try { $old = Get-WebexSecretStore } catch { }

        if (-not $ClientId)     { $ClientId     = $old.ClientId }
        if (-not $ClientSecret) { $ClientSecret = $old.ClientSecret }
        if (-not $RefreshToken) { $RefreshToken = $old.RefreshToken }
        if (-not $ClientId -or -not $ClientSecret -or -not $RefreshToken) {
            throw 'Client ID, client secret and refresh token are all needed the first time.'
        }
        if ($ClientId -notmatch '^C') {
            Write-Warning 'Client ID normally starts with "C". Make sure this is not the Org ID or Service App ID.'
        }

        Save-WebexSecretStore -Store @{
            ClientId          = $ClientId
            ClientSecret      = $ClientSecret
            RefreshToken      = $RefreshToken
            AccessToken       = $null
            AccessExpiresUtc  = [datetime]::MinValue
            RefreshExpiresUtc = $null
            UpdatedUtc        = [datetime]::UtcNow
            Account           = Get-OnCallAccountName
        }

        try { $null = Get-WebexAccessToken -Force }
        catch {
            if ($old) { Save-WebexSecretStore -Store $old }
            $kept = if ($old) { ' The previous keys were kept.' } else { '' }
            throw "$($_.Exception.Message)$kept"
        }
    }
    if ($interactive) {
        Write-Host "Credentials saved and verified for $(Get-OnCallAccountName)." -ForegroundColor Green
    }
    Get-WebexTokenStatus
}

function Get-WebexTokenStatus {
    $store = Get-WebexSecretStore
    $daysLeft = if ($store.RefreshExpiresUtc) {
        [math]::Floor(($store.RefreshExpiresUtc - [datetime]::UtcNow).TotalDays)
    } else { $null }

    [pscustomobject]@{
        Account              = $store.Account
        ClientIdHint         = if ($store.ClientId) { '...' + $store.ClientId.Substring([math]::Max(0, $store.ClientId.Length - 6)) } else { $null }
        AccessExpiresLocal   = $store.AccessExpiresUtc.ToLocalTime()
        RefreshExpiresLocal  = if ($store.RefreshExpiresUtc) { $store.RefreshExpiresUtc.ToLocalTime() } else { $null }
        RefreshDaysRemaining = $daysLeft
        LastRefreshLocal     = $store.UpdatedUtc.ToLocalTime()
    }
}

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

function Get-WebexAccessToken {
    <#
    .SYNOPSIS
    Returns a valid access token, refreshing it when it has under an hour left
    (or when -Force is used). Saves any rotated refresh token.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    Use-WebexSecretLock {
        $store = Get-WebexSecretStore

        # Refresh when the access token is close to expiring, and at least once a day anyway.
        # Each refresh restarts the refresh token's 90-day clock, so it never runs out while the app runs.
        $fresh = $store.AccessToken -and
                 $store.AccessExpiresUtc -gt [datetime]::UtcNow.AddHours(1) -and
                 $store.UpdatedUtc -gt [datetime]::UtcNow.AddDays(-1)
        if (-not $Force -and $fresh) {
            return ConvertFrom-SecureString -SecureString $store.AccessToken -AsPlainText
        }

        $body = @{
            grant_type    = 'refresh_token'
            client_id     = $store.ClientId
            client_secret = ConvertFrom-SecureString -SecureString $store.ClientSecret -AsPlainText
            refresh_token = ConvertFrom-SecureString -SecureString $store.RefreshToken -AsPlainText
        }

        try {
            $resp = Invoke-WebRequest -Uri (Get-OnCallConfig).Webex.TokenUrl -Method Post -Body $body `
                        -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -TimeoutSec 15
        }
        catch {
            throw (New-WebexError -Message "Cannot reach Webex token endpoint: $($_.Exception.Message)" -StatusCode 0)
        }

        if ($resp.StatusCode -ne 200) {
            $text = Get-ResponseText $resp
            $code = try { ($text | ConvertFrom-Json).error } catch { $null }
            $msg = switch ($code) {
                'invalid_client' { 'Webex rejected the client ID or client secret.' }
                'invalid_grant'  { 'Webex rejected the refresh token. It is expired or revoked, so generate a new one in the Developer Portal.' }
                default          { 'Token refresh failed.' }
            }
            throw (New-WebexError -Message $msg -StatusCode $resp.StatusCode -Body $text)
        }

        $tok = Get-ResponseText $resp | ConvertFrom-Json
        $now = [datetime]::UtcNow

        $store.AccessToken      = ConvertTo-SecureString $tok.access_token -AsPlainText -Force
        $store.AccessExpiresUtc = $now.AddSeconds([int]$tok.expires_in)
        if ($tok.refresh_token) {
            $store.RefreshToken = ConvertTo-SecureString $tok.refresh_token -AsPlainText -Force
        }
        if ($tok.refresh_token_expires_in) {
            $store.RefreshExpiresUtc = $now.AddSeconds([int]$tok.refresh_token_expires_in)
        }
        $store.UpdatedUtc = $now
        Save-WebexSecretStore -Store $store

        return $tok.access_token
    }
}

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

function New-WebexError {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$StatusCode = 0,
        [string]$Body
    )
    $detail = ''
    if ($Body) {
        $flat   = $Body -replace '\s+', ' '
        $detail = $flat.Substring(0, [math]::Min(500, $flat.Length))
    }
    $text = if ($detail) { "$Message (HTTP $StatusCode) $detail" } else { "$Message (HTTP $StatusCode)" }
    $ex = [System.Exception]::new($text)
    $ex.Data['StatusCode'] = $StatusCode
    $ex
}

function Get-ResponseText {
    param($Response)
    $c = $Response.Content
    if ($c -is [byte[]]) { return [System.Text.Encoding]::UTF8.GetString($c) }
    [string]$c
}

function Invoke-WebexConfig {
    <#
    .SYNOPSIS
    GET or PUT a team on the config-service. Retries once on 401 with a fresh token.
    Returns the raw JSON response text.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string]$Method,
        [Parameter(Mandatory)][string]$TeamId,
        [string]$Body
    )

    $w = (Get-OnCallConfig).Webex
    if (-not $w.OrgId) { throw 'Set the Webex org ID on the Settings page first.' }
    $uri = '{0}/cms/api/organization/{1}/team/{2}' -f $w.ConfigBaseUrl.TrimEnd('/'),
           [uri]::EscapeDataString($w.OrgId), [uri]::EscapeDataString($TeamId)

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $token  = Get-WebexAccessToken -Force:($attempt -eq 2)
        $params = @{
            Uri                = $uri
            Method             = $Method
            Headers            = @{ Authorization = "Bearer $token"; Accept = 'application/json' }
            SkipHttpErrorCheck = $true
            TimeoutSec         = 15
        }
        if ($Body) {
            $params.Body        = $Body
            $params.ContentType = 'application/json'
        }

        try { $resp = Invoke-WebRequest @params }
        catch {
            throw (New-WebexError -Message "Cannot reach Webex ($Method team): $($_.Exception.Message)" -StatusCode 0)
        }

        if ($resp.StatusCode -eq 401 -and $attempt -eq 1) { continue }
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return (Get-ResponseText $resp) }

        $msg = switch ($resp.StatusCode) {
            403     { "$Method team denied. The Service App lacks rights on this team." }
            404     { "$Method team failed. Team ID or Org ID not found." }
            default { "$Method team failed." }
        }
        throw (New-WebexError -Message $msg -StatusCode $resp.StatusCode -Body (Get-ResponseText $resp))
    }
}

function Get-JsonString {
    param($Node, [string]$Name)
    $v = $Node[$Name]
    if ($null -eq $v) { return $null }
    $v.ToString()
}

# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

function ConvertTo-OnCallNumber {
    <# Strips formatting and enforces 7 to 15 digits (same rules as phone.js).
       10-digit US numbers get a leading 1 so they match Webex's 11-digit format. #>
    param([Parameter(Mandatory)][string]$Number)
    $digits = $Number -replace '\D', ''
    if ($digits.Length -eq 10) { $digits = "1$digits" }
    if ($digits.Length -lt 7 -or $digits.Length -gt 15) {
        throw "Invalid number '$Number'. Must be 7 to 15 digits after removing formatting."
    }
    $digits
}

# ---------------------------------------------------------------------------
# Teams
# ---------------------------------------------------------------------------

function Get-WebexTeam {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TeamId)

    $raw  = Invoke-WebexConfig -Method GET -TeamId $TeamId
    $node = [System.Text.Json.Nodes.JsonNode]::Parse($raw)

    [pscustomobject]@{
        TeamId       = $TeamId
        Name         = Get-JsonString $node 'name'
        TeamType     = Get-JsonString $node 'teamType'
        DialedNumber = Get-JsonString $node 'dialedNumber'
    }
}

function Set-WebexTeamDialNumber {
    <#
    .SYNOPSIS
    Sets a team's dialedNumber. GETs the full team, changes only dialedNumber,
    PUTs it back. Skips the PUT when the number already matches.
    Supports -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$TeamId,
        [Parameter(Mandatory)][string]$DialNumber
    )

    $digits = ConvertTo-OnCallNumber $DialNumber
    $raw    = Invoke-WebexConfig -Method GET -TeamId $TeamId
    $node   = [System.Text.Json.Nodes.JsonNode]::Parse($raw)
    $name   = Get-JsonString $node 'name'
    $before = Get-JsonString $node 'dialedNumber'

    $result = [ordered]@{
        TeamId    = $TeamId
        Name      = $name
        Previous  = $before
        Requested = $digits
        Status    = $null
    }

    if ($before -eq $digits) {
        $result.Status = 'NoChange'
        return [pscustomobject]$result
    }

    if (-not $PSCmdlet.ShouldProcess($name, "Set dialedNumber $before -> $digits")) {
        $result.Status = 'WhatIf'
        return [pscustomobject]$result
    }

    $node['dialedNumber'] = [System.Text.Json.Nodes.JsonValue]::Create([string]$digits)
    $null = Invoke-WebexConfig -Method PUT -TeamId $TeamId -Body $node.ToJsonString()

    $result.Status = 'Changed'
    [pscustomobject]$result
}

Export-ModuleMember -Function Initialize-WebexModule, Get-OnCallConfig, Set-OnCallConfig, Set-WebexCredential,
    Get-OnCallAccountName, Get-OnCallKeyProtection, Read-OnCallSecretFile, Write-OnCallSecretFile,
    Write-OnCallPrivateFile, Get-ResponseText,
    Get-WebexTokenStatus, Get-WebexAccessToken, ConvertTo-OnCallNumber,
    Get-WebexTeam, Set-WebexTeamDialNumber
