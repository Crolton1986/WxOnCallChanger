#Requires -Version 7.4
<#
.SYNOPSIS
Stage 2 test for the On-Call Manager schedule logic. Never writes to Webex.

  .\Test-Schedule.ps1 -LoadSample   # builds a sample schedule from the October Outlook calendar
  .\Test-Schedule.ps1               # who's on call now, the next 3 weeks, and the sync preview

The sample uses fake 555 numbers. Fix them with, for example:
  Set-OnCallPerson -Person 'Sayf Ayed' -Number 5415551234
(after importing the modules the same way this script does)
#>
[CmdletBinding()]
param([switch]$LoadSample)

$ErrorActionPreference = 'Stop'
$data = Join-Path $PSScriptRoot 'data'
Import-Module (Join-Path $PSScriptRoot 'modules\Webex.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'modules\Schedule.psm1') -Force
Initialize-WebexModule -DataPath $data
Initialize-ScheduleModule -DataPath $data -TimeZoneId (Get-OnCallConfig).TimeZone

if ($LoadSample) {
    $file = Join-Path $data 'schedule.json'
    if (Test-Path $file) { throw "schedule.json already exists. Delete it first if you want the sample." }

    $support = 'Brian Thompson', 'Sean Peterson', 'Nicholas Allen', 'Christopher Russell', 'Sayf Ayed', 'Ernest Skiba'
    $systems = 'James Wood', 'Erik Jensen', 'Tom Nelson'
    $n = 101
    foreach ($name in $support) { $null = Add-OnCallPerson -Name $name -Number ('541555{0:d4}' -f $n++) -Teams support }
    foreach ($name in $systems) { $null = Add-OnCallPerson -Name $name -Number ('541555{0:d4}' -f $n++) -Teams systems }
    Set-OnCallRotation -TeamKey support -Members $support -AnchorStart '2026-10-19T08:00' -AnchorPerson 'Sayf Ayed'
    Set-OnCallRotation -TeamKey systems -Members $systems -AnchorStart '2026-10-19T08:00' -AnchorPerson 'James Wood'
    $null = Add-OnCallOverride -TeamKey support -Person 'Sayf Ayed' -Start '2026-10-17T07:00' -End '2026-10-17T17:00' -Note 'Sayf covering'
    $null = Add-OnCallOverride -TeamKey systems -Person 'James Wood' -Start '2026-10-17T00:00' -End '2026-10-19T08:00' -Note "Covering Tom's weekend"
    Write-Host 'Sample schedule created. Both switches are OFF.' -ForegroundColor Green
}

$teams = Get-OnCallTeams

Write-Host "`nOn call right now" -ForegroundColor Cyan
$teams | ForEach-Object { Get-OnCallAssignment -TeamKey $_.Key } |
    Format-Table TeamKey, PersonName, Number, Source, Note, Start, End -AutoSize

Write-Host 'Next 3 weeks' -ForegroundColor Cyan
$from = (Get-Date).Date
foreach ($t in $teams) {
    Write-Host "  $($t.DisplayName)"
    Get-OnCallSlots -TeamKey $t.Key -From $from -To $from.AddDays(21) | ForEach-Object {
        '    {0:ddd MM/dd HH:mm} -> {1:ddd MM/dd HH:mm}  {2,-20} {3,-9} {4}' -f $_.Start, $_.End, $_.PersonName, $_.Source, $_.Note
    }
}

Write-Host "`nSync preview (read-only)" -ForegroundColor Cyan
Get-OnCallSyncPlan | Format-Table TeamKey, Enabled, Person, Source, Desired, Current, Action, Error -AutoSize -Wrap
