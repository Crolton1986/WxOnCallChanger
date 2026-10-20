#Requires -Version 7.4
# Webex.psm1
# Webex Contact Center config-service client for the On-Call Manager.
# Ported from ACH_OnCall_Manager.ps1, with Service App auth instead of user OAuth.
#
# PUT semantics (same as the original script): GET the full team object,
# change ONLY dialedNumber, PUT the whole object back.
# Uses System.Text.Json so every other field round-trips byte for byte
# (ConvertFrom-Json in PS7 rewrites date strings, which we don't want to PUT back).
#
# Secrets live in data\secrets.clixml, encrypted with DPAPI. Only the Windows
# account that ran Set-WebexCredential, on this machine, can read them.

$script:Config      = $null
$script:SecretsFile = $null

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

function Initialize-WebexModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataPath)

    $resolved   = (Resolve-Path -LiteralPath $DataPath).Path
    $configFile = Join-Path $resolved 'config.json'
    if (-not (Test-Path -LiteralPath $configFile)) {
        throw "config.json not found in $resolved"
    }
    $script:Config      = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json -AsHashtable
    $script:SecretsFile = Join-Path $resolved 'secrets.clixml'
}

function Assert-WebexInit {
    if ($script:Config) { return }
    if ($env:ONCALL_DATA) { Initialize-WebexModule -DataPath $env:ONCALL_DATA; return }
    throw 'Run Initialize-WebexModule first.'
}

function Get-OnCallConfig {
    Assert-WebexInit
    $script:Config
}

# ---------------------------------------------------------------------------
# Secret store (DPAPI via Export-Clixml)
# ---------------------------------------------------------------------------

function Use-WebexSecretLock {
    <#
    Runs a script block while holding a named lock on the keys file, so the web page and the
    5-minute check never read or write it at the same time. The lock is re-entrant on one thread.
    #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)
    Assert-WebexInit
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($script:SecretsFile.ToLowerInvariant()))).Substring(0, 16)
    $m = [System.Threading.Mutex]::new($false, "Local\OnCallManager-$hash")
    $owned = $false
    try {
        try { $owned = $m.WaitOne(30000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Timed out waiting for the Webex keys file.' }
        & $ScriptBlock
    }
    finally {
        if ($owned) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Get-WebexSecretStore {
    Assert-WebexInit
    Use-WebexSecretLock {
        if (-not (Test-Path -LiteralPath $script:SecretsFile)) {
            throw 'No Webex credentials stored. Run Set-WebexCredential as the account that will run the service.'
        }
        Import-Clixml -LiteralPath $script:SecretsFile
    }
}

function Save-WebexSecretStore {
    param([Parameter(Mandatory)][hashtable]$Store)
    Use-WebexSecretLock {
        # Write a temp file and swap it in, so a crash mid-write never leaves a broken keys file.
        $tmp = "$($script:SecretsFile).tmp"
        $Store | Export-Clixml -LiteralPath $tmp -Force
        Move-Item -LiteralPath $tmp -Destination $script:SecretsFile -Force
    }
}

function Set-WebexCredential {
    <#
    .SYNOPSIS
    Saves the Service App client ID, client secret and refresh token, encrypted to the
    current Windows account, then proves them with a token refresh. If the test fails,
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
            Account           = "$env:USERDOMAIN\$env:USERNAME"
        }

        try { $null = Get-WebexAccessToken -Force }
        catch {
            if ($old) { Save-WebexSecretStore -Store $old }
            $kept = if ($old) { ' The previous keys were kept.' } else { '' }
            throw "$($_.Exception.Message)$kept"
        }
    }
    if ($interactive) {
        Write-Host "Credentials saved and verified for $env:USERDOMAIN\$env:USERNAME." -ForegroundColor Green
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
            $resp = Invoke-WebRequest -Uri $script:Config.Webex.TokenUrl -Method Post -Body $body `
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

    Assert-WebexInit
    $w   = $script:Config.Webex
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

Export-ModuleMember -Function Initialize-WebexModule, Get-OnCallConfig, Set-WebexCredential,
    Get-WebexTokenStatus, Get-WebexAccessToken, ConvertTo-OnCallNumber,
    Get-WebexTeam, Set-WebexTeamDialNumber
