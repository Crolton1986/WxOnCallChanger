#Requires -Version 7.4
<#
.SYNOPSIS
Stage 1 test for the On-Call Manager Webex module.

.DESCRIPTION
Default run is read-only: refreshes the Service App token, then reads each
configured team's current dialedNumber.

  .\Test-Webex.ps1 -SetupCredential   # first time: prompt for and store Service App creds
  .\Test-Webex.ps1                    # read-only check of both teams
  .\Test-Webex.ps1 -TeamKey support -SetNumber 15415551234 -WhatIf   # dry run of a change
  .\Test-Webex.ps1 -TeamKey support -SetNumber 15415551234           # real change
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SetupCredential,
    [string]$TeamKey,
    [string]$SetNumber
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'modules\Webex.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Schedule.psm1') -Force
Initialize-WebexModule -DataPath (Join-Path $PSScriptRoot 'data')
Initialize-ScheduleModule -DataPath (Join-Path $PSScriptRoot 'data') -TimeZoneId (Get-OnCallConfig).TimeZone

if ($SetupCredential) {
    Set-WebexCredential
}

Write-Host "`nToken" -ForegroundColor Cyan
$null = Get-WebexAccessToken
Get-WebexTokenStatus | Format-List

Write-Host "Teams" -ForegroundColor Cyan
$teams = Get-OnCallTeams
$rows = foreach ($t in $teams) {
    try {
        $team = Get-WebexTeam -TeamId $t.WebexTeamId
        [pscustomobject]@{
            Key          = $t.Key
            WebexName    = $team.Name
            Type         = $team.TeamType
            DialedNumber = $team.DialedNumber
            Error        = $null
        }
    }
    catch {
        [pscustomobject]@{
            Key          = $t.Key
            WebexName    = $null
            Type         = $null
            DialedNumber = $null
            Error        = $_.Exception.Message
        }
    }
}
$rows | Format-Table -AutoSize -Wrap

if ($SetNumber) {
    if (-not $TeamKey) { throw 'Use -TeamKey with -SetNumber.' }
    $t = $teams | Where-Object { $_.Key -eq $TeamKey }
    if (-not $t) { throw "No team with key '$TeamKey'. Keys: $(($teams.Key) -join ', ')" }

    Write-Host "Change" -ForegroundColor Cyan
    Set-WebexTeamDialNumber -TeamId $t.WebexTeamId -DialNumber $SetNumber -WhatIf:$WhatIfPreference |
        Format-List
}
