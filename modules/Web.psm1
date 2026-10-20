#Requires -Version 7.4
# Web.psm1
# Glue between the Pode routes and the Webex/Schedule modules.
# Every API response is a JSON object. Lists are wrapped as { items: [...] }.

function Invoke-OnCallApi {
    <#
    Runs a route body, returns its last output as JSON, and turns errors into
    HTTP 400 { error }. -Lock serializes writes with the scheduler.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][scriptblock]$ScriptBlock,
        [switch]$Lock
    )
    try {
        Set-OnCallActor 'web'
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
    <# FullCalendar sends ISO strings with an offset, or plain dates. Returns Pacific wall-clock. #>
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
            runningAs = "$env:USERDOMAIN\$env:USERNAME"
            checkMinutes = Get-OnCallCheckMinutes
        }
    }
    catch { @{ saved = $false; runningAs = "$env:USERDOMAIN\$env:USERNAME"; error = $_.Exception.Message; checkMinutes = Get-OnCallCheckMinutes } }
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

Export-ModuleMember -Function Get-OnCallTeamsView, Get-OnCallCredentialStatus, Update-OnCallCredential, Invoke-OnCallApi, Get-OnCallStatus, Get-OnCallEvents, ConvertFrom-ClientTime
