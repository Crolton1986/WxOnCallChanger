#Requires -Version 7.4
# Auth.psm1
# Sign-in for network mode: "Sign in with Webex" (OAuth Integration), an allow-list of emails,
# cookie sessions, and the one-time setup that stores the Integration keys.
#
# Someone gets in when Webex says they belong to the org in config.json (Webex.OrgId) AND one
# of their emails is on the list managed on Settings. Their Webex token is used once, to read
# /v1/people/me, and then dropped. Sessions live in memory, so a restart signs everyone out.
#
# Depends on Webex.psm1 (config, secret files) and Schedule.psm1 (sign-in list, audit).

$script:SessionIdleHours = 8
$script:LoginScope       = 'spark:people_read'

# ---------------------------------------------------------------------------
# Login Integration keys
# ---------------------------------------------------------------------------

function Get-OnCallLoginStore { Read-OnCallSecretFile -Name 'login' }

function Set-OnCallLoginIntegration {
    <# Saves the Webex Integration used for sign-in. A blank value keeps the saved one. #>
    param([string]$ClientId, [string]$ClientSecret)
    $old = try { Get-OnCallLoginStore } catch { $null }
    $id  = "$ClientId".Trim()
    $sec = "$ClientSecret".Trim()
    if (-not $id  -and $old) { $id = $old.ClientId }
    $secure = if ($sec) { ConvertTo-SecureString $sec -AsPlainText -Force } elseif ($old) { $old.ClientSecret } else { $null }
    if (-not $id -or -not $secure) { throw 'Both the Integration client ID and client secret are needed.' }
    if ($id -notmatch '^C[0-9a-f]{20,}$') { throw "'$id' doesn't look like an Integration client ID (it starts with C)." }
    Write-OnCallSecretFile -Name 'login' -Store @{ ClientId = $id; ClientSecret = $secure; UpdatedUtc = [datetime]::UtcNow }
}

function Test-OnCallLoginReady {
    <# True once sign-in can work: Integration keys saved, org ID set, someone on the list. #>
    try { $s = Get-OnCallLoginStore } catch { return $false }
    [bool]($s -and $s.ClientId -and (Get-OnCallConfig).Webex.OrgId -and @(Get-OnCallUser).Count)
}

function Get-OnCallLoginStatus {
    param([string]$RedirectUri)
    $s = $null; $err = $null
    try { $s = Get-OnCallLoginStore } catch { $err = $_.Exception.Message }
    @{
        saved        = [bool]$s
        clientIdHint = if ($s.ClientId) { '...' + $s.ClientId.Substring([math]::Max(0, $s.ClientId.Length - 6)) } else { $null }
        redirectUri  = $RedirectUri
        error        = $err
    }
}

# ---------------------------------------------------------------------------
# Webex OAuth
# ---------------------------------------------------------------------------

function New-OnCallRandomToken {
    param([int]$Bytes = 32)
    [Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Bytes)).
        TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-OnCallAuthorizeUrl {
    param([Parameter(Mandatory)][string]$State, [Parameter(Mandatory)][string]$RedirectUri)
    $s = Get-OnCallLoginStore
    if (-not $s) { throw 'Sign-in isn''t set up yet.' }
    $base = (Get-OnCallConfig).Webex.AuthBaseUrl.TrimEnd('/')
    $q = [ordered]@{
        client_id = $s.ClientId; response_type = 'code'; redirect_uri = $RedirectUri
        scope = $script:LoginScope; state = $State
    }
    "$base/v1/authorize?" + (($q.Keys | ForEach-Object { "$_=$([uri]::EscapeDataString($q[$_]))" }) -join '&')
}

function ConvertTo-OnCallOrgUuid {
    <# Webex REST APIs return org IDs base64-encoded ("ciscospark://us/ORGANIZATION/<uuid>");
       Contact Center and Control Hub show the bare UUID. Returns the UUID either way. #>
    param([string]$Value)
    if (-not $Value) { return $null }
    $g = [guid]::Empty
    if ([guid]::TryParse($Value, [ref]$g)) { return $g.ToString() }
    try {
        $b = $Value.Replace('-', '+').Replace('_', '/')
        $b += '=' * ((4 - $b.Length % 4) % 4)
        $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b))
        $last = ($text -split '/')[-1]
        if ([guid]::TryParse($last, [ref]$g)) { return $g.ToString() }
    }
    catch {
        # Not base64 or not an org URI: fall through and compare the raw value.
        Write-Verbose "Org ID '$Value' isn't a Webex base64 ID: $($_.Exception.Message)"
    }
    $Value.ToLowerInvariant()
}

function Invoke-OnCallLoginExchange {
    <# Trades the authorization code for a token, reads who signed in, and drops the token. #>
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$RedirectUri)
    $s    = Get-OnCallLoginStore
    $base = (Get-OnCallConfig).Webex.AuthBaseUrl.TrimEnd('/')
    $body = @{
        grant_type = 'authorization_code'; code = $Code; redirect_uri = $RedirectUri
        client_id = $s.ClientId; client_secret = (ConvertFrom-SecureString $s.ClientSecret -AsPlainText)
    }
    $resp = Invoke-WebRequest -Uri "$base/v1/access_token" -Method Post -Body $body `
                -ContentType 'application/x-www-form-urlencoded' -SkipHttpErrorCheck -TimeoutSec 15
    if ($resp.StatusCode -ne 200) {
        $code = try { ((Get-ResponseText $resp) | ConvertFrom-Json).error } catch { $null }
        throw "Webex didn't accept the sign-in (HTTP $($resp.StatusCode) $code). Check the Integration keys and redirect URI on Settings."
    }
    $token = ((Get-ResponseText $resp) | ConvertFrom-Json).access_token

    $me = Invoke-WebRequest -Uri "$base/v1/people/me" -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck -TimeoutSec 15
    if ($me.StatusCode -ne 200) { throw "Webex wouldn't say who signed in (HTTP $($me.StatusCode))." }
    $p = (Get-ResponseText $me) | ConvertFrom-Json
    [pscustomobject]@{
        Emails = @($p.emails | Where-Object { $_ } | ForEach-Object { "$_".Trim().ToLowerInvariant() })
        Name   = "$($p.displayName)"
        OrgId  = ConvertTo-OnCallOrgUuid $p.orgId
    }
}

function Test-OnCallLoginAllowed {
    <# Returns @{ Allowed; Email; Reason } for a person from Invoke-OnCallLoginExchange. #>
    param([Parameter(Mandatory)]$Person)
    $email = @($Person.Emails)[0]
    $org   = ConvertTo-OnCallOrgUuid (Get-OnCallConfig).Webex.OrgId
    if (-not $org -or $Person.OrgId -ne $org) {
        return @{ Allowed = $false; Email = $email; Reason = 'wrong_org' }
    }
    foreach ($e in $Person.Emails) {
        if (Test-OnCallUserAllowed -Email $e) { return @{ Allowed = $true; Email = $e; Reason = $null } }
    }
    @{ Allowed = $false; Email = $email; Reason = 'not_listed' }
}

# ---------------------------------------------------------------------------
# Sessions (server-side, in memory; the cookie holds only a random ID)
# ---------------------------------------------------------------------------

function New-OnCallSession {
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)][string]$Email, [string]$Name)
    $id = New-OnCallRandomToken 32
    $Store[$id] = @{ Email = $Email; Name = $Name; LastSeenUtc = [datetime]::UtcNow }
    $id
}

function Get-OnCallSession {
    <# The session for a cookie value, or $null. Idle sessions expire; each use extends it. #>
    param([Parameter(Mandatory)]$Store, [string]$Id)
    if (-not $Id) { return $null }
    $s = $null
    if (-not $Store.TryGetValue($Id, [ref]$s)) { return $null }
    if ($s.LastSeenUtc -lt [datetime]::UtcNow.AddHours(-$script:SessionIdleHours)) {
        $null = $Store.TryRemove($Id, [ref]$s)
        return $null
    }
    # Someone taken off the list loses access at their next request, not just at next sign-in.
    if (-not (Test-OnCallUserAllowed -Email $s.Email)) {
        $null = $Store.TryRemove($Id, [ref]$s)
        return $null
    }
    $s.LastSeenUtc = [datetime]::UtcNow
    $s
}

function Remove-OnCallSession {
    param([Parameter(Mandatory)]$Store, [string]$Id)
    $s = $null
    if ($Id) { $null = $Store.TryRemove($Id, [ref]$s) }
}

function Get-OnCallCookieValue {
    <# Reads one cookie from a raw Cookie header. #>
    param([string]$Header, [Parameter(Mandatory)][string]$Name)
    foreach ($part in "$Header" -split ';') {
        $kv = $part.Trim() -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0] -eq $Name) { return [uri]::UnescapeDataString($kv[1]) }
    }
    $null
}

function New-OnCallCookieHeader {
    <# Set-Cookie value. Lax (not Strict) so the cookie comes back on the redirect from Webex. #>
    param([Parameter(Mandatory)][string]$Name, [string]$Value = '', [int]$MaxAgeSeconds = -1)
    $c = "$Name=$([uri]::EscapeDataString($Value)); Path=/; Secure; HttpOnly; SameSite=Lax"
    if ($MaxAgeSeconds -ge 0) { $c += "; Max-Age=$MaxAgeSeconds" }
    $c
}

# ---------------------------------------------------------------------------
# One-time setup
# ---------------------------------------------------------------------------

function New-OnCallSetupCode {
    <# 8 characters without look-alikes (no 0/O, 1/I/L). #>
    $alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'
    -join ([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(8) | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
}

function Test-OnCallSetupCode {
    <# Constant-time compare, ignoring case, spaces and dashes. #>
    param([string]$Given, [string]$Expected)
    $a = [Text.Encoding]::UTF8.GetBytes(("$Given" -replace '[\s-]', '').ToUpperInvariant())
    $b = [Text.Encoding]::UTF8.GetBytes("$Expected".ToUpperInvariant())
    [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b)
}

function Complete-OnCallSetup {
    <# Saves the org ID, the Integration keys and the first person who can sign in. #>
    param(
        [Parameter(Mandatory)][string]$OrgId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret,
        [Parameter(Mandatory)][string]$Email
    )
    $null = Set-OnCallConfig -OrgId $OrgId
    if (-not (Get-OnCallConfig).Webex.OrgId) { throw 'The org ID is required.' }
    Set-OnCallLoginIntegration -ClientId $ClientId -ClientSecret $ClientSecret
    Set-OnCallActor 'setup'
    $e = "$Email".Trim().ToLowerInvariant()
    if (-not (Test-OnCallUserAllowed -Email $e)) { $null = Add-OnCallUser -Email $e }
    Write-OnCallAudit -Event 'setup' -Detail "Sign-in set up; $e can sign in"
}

Export-ModuleMember -Function Get-OnCallLoginStore, Set-OnCallLoginIntegration, Test-OnCallLoginReady,
    Get-OnCallLoginStatus, New-OnCallRandomToken, Get-OnCallAuthorizeUrl, ConvertTo-OnCallOrgUuid,
    Invoke-OnCallLoginExchange, Test-OnCallLoginAllowed, New-OnCallSession, Get-OnCallSession,
    Remove-OnCallSession, Get-OnCallCookieValue, New-OnCallCookieHeader, New-OnCallSetupCode,
    Test-OnCallSetupCode, Complete-OnCallSetup
