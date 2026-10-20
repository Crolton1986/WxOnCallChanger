#Requires -Version 7.4
# Schedule.psm1
# Works out who should be on call for each team at a given time, and syncs Webex to match.
#
# Data lives in data\schedule.json (teams, people, rotations, covers, on/off switches).
# All schedule times are Pacific wall-clock times, stored as "yyyy-MM-ddTHH:mm".
#
# Every schedule source produces "slots": team, person, start, end, priority.
# Today the sources are the weekly rotation (priority 10) and covers (priority 20).
# A future Outlook/Graph source just needs to return slots in the same shape.
#
# Depends on Webex.psm1 (Get-OnCallConfig, Get-WebexTeam, Set-WebexTeamDialNumber,
# ConvertTo-OnCallNumber). Import that first.

$script:DataPath = $null
$script:Tz       = $null
$script:WallFmt  = 'yyyy-MM-ddTHH:mm'
$script:Actor    = $null   # who is making changes in this runspace; null = the Windows account
$script:Colors   = 8       # size of the team color palette in app.css (tc-0 .. tc-7)

# ---------------------------------------------------------------------------
# Setup and storage
# ---------------------------------------------------------------------------

function Initialize-ScheduleModule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataPath,
        [string]$TimeZoneId = 'Pacific Standard Time'
    )
    if ([string]::IsNullOrWhiteSpace($TimeZoneId)) { $TimeZoneId = 'Pacific Standard Time' }
    $script:DataPath = (Resolve-Path -LiteralPath $DataPath).Path
    $script:Tz       = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
}

function Assert-ScheduleInit {
    if ($script:DataPath -and $script:Tz) { return }
    if ($env:ONCALL_DATA) { Initialize-ScheduleModule -DataPath $env:ONCALL_DATA -TimeZoneId $env:ONCALL_TZ; return }
    throw 'Run Initialize-ScheduleModule first.'
}

function Get-SchedulePath { param([string]$Name) Assert-ScheduleInit; Join-Path $script:DataPath $Name }

function Get-ScheduleData {
    $file = Get-SchedulePath 'schedule.json'
    $d = if (Test-Path -LiteralPath $file) { Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable } else { @{} }

    foreach ($k in 'People', 'Overrides') { $d[$k] = @($d[$k] | Where-Object { $_ }) }
    if (-not $d.Rotations) { $d.Rotations = @{} }
    if (-not $d.Switches)  { $d.Switches  = @{ Global = $false; Teams = @{} } }
    if (-not $d.Switches.Teams) { $d.Switches.Teams = @{} }
    if (-not $d.Settings) { $d.Settings = @{} }
    if (-not $d.Settings.CheckMinutes) { $d.Settings.CheckMinutes = 30 }

    # Teams used to live in config.json. Bring them over the first time.
    if ($null -eq $d.Teams) {
        $i = 0
        $d.Teams = @(foreach ($t in @((Get-OnCallConfig).Teams)) {
            @{ Key = $t.Key; DisplayName = $t.DisplayName; WebexTeamId = $t.WebexTeamId; Color = ($i++ % $script:Colors) }
        })
    }
    $d.Teams = @($d.Teams | Where-Object { $_ })

    # People used to have no team list. Start them on the teams whose rotation they're in.
    foreach ($p in $d.People) {
        if ($null -eq $p.Teams) {
            $p.Teams = @(foreach ($k in $d.Rotations.Keys) { if (@($d.Rotations[$k].Members) -contains $p.Id) { $k } })
        }
        $p.Teams = @($p.Teams | Where-Object { $_ })
    }
    $d
}

function Save-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Object)
    $tmp = "$Path.tmp"
    $Object | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Save-ScheduleData {
    param([Parameter(Mandatory)][hashtable]$Data)
    Save-JsonAtomic -Path (Get-SchedulePath 'schedule.json') -Object $Data
}

# ---------------------------------------------------------------------------
# Time helpers (everything inside the module is Pacific wall-clock)
# ---------------------------------------------------------------------------

function ConvertTo-ScheduleLocal {
    <# Any DateTime -> Pacific wall-clock DateTime (Kind Unspecified). #>
    param([Parameter(Mandatory)][datetime]$Time)
    Assert-ScheduleInit
    if ($Time.Kind -eq 'Unspecified') { return $Time }   # already wall-clock
    [TimeZoneInfo]::ConvertTime([DateTimeOffset]$Time, $script:Tz).DateTime
}

function ConvertFrom-WallString {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [datetime]) { return [datetime]::SpecifyKind($Value, 'Unspecified') }
    # Pode's JSON parser turns "2026-10-19T08:00:00" into a DateTime, and binding that to a
    # [string] parameter gives "10/19/2026 08:00:00". Accept both shapes.
    $formats = [string[]]@($script:WallFmt, 'yyyy-MM-ddTHH:mm:ss', 'yyyy-MM-dd', 'MM/dd/yyyy HH:mm:ss', 'M/d/yyyy H:mm:ss', 'MM/dd/yyyy HH:mm')
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParseExact([string]$Value, $formats, [cultureinfo]::InvariantCulture, 'None', [ref]$dt)) {
        throw "'$Value' is not a date and time this app understands."
    }
    [datetime]::SpecifyKind($dt, 'Unspecified')
}

function ConvertTo-WallString { param([datetime]$Time) $Time.ToString($script:WallFmt, [cultureinfo]::InvariantCulture) }

function Get-NowLocal { ConvertTo-ScheduleLocal ([datetime]::UtcNow) }

function Format-Friendly { param([datetime]$Time) $Time.ToString('ddd MMM d, h:mm tt', [cultureinfo]::InvariantCulture) }

# ---------------------------------------------------------------------------
# Teams
# ---------------------------------------------------------------------------

function Resolve-OnCallTeam {
    param([Parameter(Mandatory)][hashtable]$Data, [Parameter(Mandatory)][string]$TeamKey)
    $t = $Data.Teams | Where-Object { $_.Key -eq $TeamKey } | Select-Object -First 1
    if (-not $t) { throw "No team '$TeamKey'." }
    $t
}

function Get-OnCallTeams {
    @((Get-ScheduleData).Teams | ForEach-Object { [pscustomobject]$_ })
}

function Assert-WebexTeamId {
    <# Checks the UUID format and that Webex can read it. Returns what Webex has. #>
    param([Parameter(Mandatory)][string]$WebexTeamId)
    $g = [guid]::Empty
    if (-not [guid]::TryParse($WebexTeamId.Trim(), [ref]$g)) { throw "'$WebexTeamId' is not a team UUID." }
    try { Get-WebexTeam -TeamId $g.ToString() }
    catch { throw "Webex could not read team $g. $($_.Exception.Message)" }
}

function Add-OnCallTeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$WebexTeamId
    )
    $DisplayName = $DisplayName.Trim()
    if (-not $DisplayName) { throw 'Give the team a name.' }
    $wx   = Assert-WebexTeamId $WebexTeamId
    $data = Get-ScheduleData
    if ($data.Teams | Where-Object { $_.WebexTeamId -eq $wx.TeamId }) { throw "Team $($wx.TeamId) is already set up." }
    if ($data.Teams | Where-Object { $_.DisplayName -eq $DisplayName }) { throw "There is already a team called '$DisplayName'." }

    $base = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if (-not $base) { $base = 'team' }
    $key = $base; $n = 2
    while ($data.Teams | Where-Object { $_.Key -eq $key }) { $key = "$base-$n"; $n++ }

    $used  = @($data.Teams | ForEach-Object { [int]$_.Color })
    $color = (0..($script:Colors - 1) | Where-Object { $_ -notin $used } | Select-Object -First 1)
    if ($null -eq $color) { $color = $data.Teams.Count % $script:Colors }

    $t = @{ Key = $key; DisplayName = $DisplayName; WebexTeamId = $wx.TeamId; Color = $color }
    $data.Teams = @($data.Teams) + $t
    $data.Switches.Teams[$key] = $false
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'team_add' -TeamKey $key -Detail "$DisplayName ($($wx.TeamId)), Webex team '$($wx.Name)'"
    [pscustomobject]($t + @{ WebexName = $wx.Name; Current = $wx.DialedNumber })
}

function Set-OnCallTeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [string]$DisplayName,
        [string]$WebexTeamId
    )
    $data = Get-ScheduleData
    $t = Resolve-OnCallTeam $data $TeamKey
    $changes = @()
    if ($DisplayName -and $DisplayName.Trim() -ne $t.DisplayName) {
        $DisplayName = $DisplayName.Trim()
        if ($data.Teams | Where-Object { $_.Key -ne $TeamKey -and $_.DisplayName -eq $DisplayName }) { throw "There is already a team called '$DisplayName'." }
        $changes += "name '$($t.DisplayName)' to '$DisplayName'"
        $t.DisplayName = $DisplayName
    }
    if ($WebexTeamId -and $WebexTeamId.Trim() -ne $t.WebexTeamId) {
        $wx = Assert-WebexTeamId $WebexTeamId
        if ($data.Teams | Where-Object { $_.Key -ne $TeamKey -and $_.WebexTeamId -eq $wx.TeamId }) { throw "Team $($wx.TeamId) is already set up." }
        $changes += "Webex team to $($wx.TeamId) ('$($wx.Name)')"
        $t.WebexTeamId = $wx.TeamId
    }
    if ($changes) {
        Save-ScheduleData $data
        Write-OnCallAudit -Event 'team_update' -TeamKey $TeamKey -Detail ("Changed " + ($changes -join ', '))
    }
    [pscustomobject]$t
}

function Remove-OnCallTeam {
    <#
    Refuses while anyone is still on the team or any of its covers end after now.
    Then removes the team with its rotation, past covers and switch. History keeps the record.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TeamKey)
    $data = Get-ScheduleData
    $t = Resolve-OnCallTeam $data $TeamKey

    $members = @($data.People | Where-Object { @($_.Teams) -contains $TeamKey })
    $now     = Get-NowLocal
    $future  = @($data.Overrides | Where-Object { $_.TeamKey -eq $TeamKey -and (ConvertFrom-WallString $_.End) -gt $now })
    $why = @()
    if ($members) { $why += "take these people off it first: $(($members.Name | Sort-Object) -join ', ')" }
    if ($future)  { $why += "delete its $($future.Count) upcoming cover$(if ($future.Count -ne 1) { 's' }) from the calendar" }
    if ($why) { throw "$($t.DisplayName) can't be removed yet. On the People page and the calendar, $($why -join '; and ')." }

    $data.Teams     = @($data.Teams | Where-Object { $_.Key -ne $TeamKey })
    $data.Overrides = @($data.Overrides | Where-Object { $_.TeamKey -ne $TeamKey })
    $data.Rotations.Remove($TeamKey)
    $data.Switches.Teams.Remove($TeamKey)
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'team_remove' -TeamKey $TeamKey -Detail "$($t.DisplayName) ($($t.WebexTeamId))"
}

# ---------------------------------------------------------------------------
# People
# ---------------------------------------------------------------------------

function Resolve-OnCallPerson {
    <# Find a person by Id or by name (case-insensitive). #>
    param([Parameter(Mandatory)][hashtable]$Data, [Parameter(Mandatory)][string]$Person)
    $p = $Data.People | Where-Object { $_.Id -eq $Person -or $_.Name -eq $Person } | Select-Object -First 1
    if (-not $p) { throw "No person '$Person' in the phonebook." }
    $p
}

function Test-OnTeam { param($Person, [string]$TeamKey) @($Person.Teams) -contains $TeamKey }

function Get-OnCallPerson {
    (Get-ScheduleData).People | ForEach-Object { [pscustomobject]$_ }
}

function Add-OnCallPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Number,
        [string[]]$Teams = @()
    )
    $data = Get-ScheduleData
    $Name = $Name.Trim()
    if ($data.People | Where-Object { $_.Name -eq $Name }) { throw "'$Name' is already in the phonebook." }
    foreach ($k in $Teams) { $null = Resolve-OnCallTeam $data $k }
    $p = @{
        Id     = [guid]::NewGuid().ToString('n').Substring(0, 8)
        Name   = $Name
        Number = (ConvertTo-OnCallNumber $Number)
        Teams  = @($Teams | Select-Object -Unique)
    }
    $data.People = @($data.People) + $p
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'person_add' -Detail "$Name $($p.Number)"
    [pscustomobject]$p
}

function Remove-RotationMember {
    <#
    Takes a person out of a team's rotation without moving this week:
    whoever is on now stays on until the next handoff, and the cycle continues from there
    without the removed person. If the removed person is on now, the next person takes over.
    #>
    param([hashtable]$Data, [string]$TeamKey, [string]$PersonId)
    $rot = $Data.Rotations[$TeamKey]
    if (-not $rot -or @($rot.Members) -notcontains $PersonId) { return $false }

    $members = @($rot.Members)
    $n       = $members.Count
    $anchor  = ConvertFrom-WallString $rot.AnchorStart
    $w       = [math]::Floor(((Get-NowLocal) - $anchor).TotalDays / 7)
    $weekStart = $anchor.AddDays(7 * $w)
    $idxNow  = ((([int]$rot.AnchorIndex + $w) % $n) + $n) % $n
    $keepOn  = if ($members[$idxNow] -ne $PersonId) { $members[$idxNow] } else { $members[($idxNow + 1) % $n] }

    $left = @($members | Where-Object { $_ -ne $PersonId })
    if (-not $left) { $Data.Rotations.Remove($TeamKey); return $true }
    $Data.Rotations[$TeamKey] = @{
        Members     = $left
        AnchorStart = ConvertTo-WallString $weekStart
        AnchorIndex = [array]::IndexOf([string[]]$left, $keepOn)
    }
    return $true
}

function Set-OnCallPerson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Person,
        [string]$Name,
        [string]$Number,
        [string[]]$Teams
    )
    $data = Get-ScheduleData
    $p = Resolve-OnCallPerson $data $Person
    if ($Name -and $Name.Trim() -ne $p.Name) {
        if ($data.People | Where-Object { $_.Id -ne $p.Id -and $_.Name -eq $Name.Trim() }) { throw "'$($Name.Trim())' is already in the phonebook." }
        $p.Name = $Name.Trim()
    }
    if ($Number) { $p.Number = ConvertTo-OnCallNumber $Number }

    $notes = @()
    if ($PSBoundParameters.ContainsKey('Teams')) {
        $want = @($Teams | Where-Object { $_ } | Select-Object -Unique)
        foreach ($k in $want) { $null = Resolve-OnCallTeam $data $k }
        $removed = @(@($p.Teams) | Where-Object { $_ -notin $want })

        $now = Get-NowLocal
        foreach ($k in $removed) {
            $t = $data.Teams | Where-Object { $_.Key -eq $k }
            $blocking = @($data.Overrides | Where-Object {
                $_.TeamKey -eq $k -and $_.PersonId -eq $p.Id -and (ConvertFrom-WallString $_.End) -gt $now })
            if ($blocking) {
                $first = Format-Friendly (ConvertFrom-WallString ($blocking | Sort-Object Start | Select-Object -First 1).Start)
                throw ("$($p.Name) still has $($blocking.Count) upcoming cover$(if ($blocking.Count -ne 1) { 's' }) on " +
                       "$($t.DisplayName) (first one $first). Delete those on the calendar first.")
            }
        }
        foreach ($k in $removed) {
            if (Remove-RotationMember $data $k $p.Id) {
                $t = $data.Teams | Where-Object { $_.Key -eq $k }
                $notes += "taken out of the $($t.DisplayName) rotation"
                Write-OnCallAudit -Event 'rotation_set' -TeamKey $k -Detail "$($p.Name) removed from the rotation. This week stays as is; later weeks shift."
            }
        }
        $added = @($want | Where-Object { $_ -notin @($p.Teams) })
        $p.Teams = $want
        $names = { param($keys) ($keys | ForEach-Object { $k = $_; ($data.Teams | Where-Object { $_.Key -eq $k }).DisplayName }) -join ', ' }
        if ($added)   { $notes += "added to $(& $names $added)" }
        if ($removed) { $notes += "removed from $(& $names $removed)" }
    }

    Save-ScheduleData $data
    $detail = "$($p.Name) $($p.Number)" + $(if ($notes) { ": " + ($notes -join '; ') } else { '' })
    Write-OnCallAudit -Event 'person_update' -Detail $detail
    [pscustomobject]$p
}

function Remove-OnCallPerson {
    <# Refuses while the person is on any team or has upcoming covers. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Person)
    $data = Get-ScheduleData
    $p = Resolve-OnCallPerson $data $Person
    if (@($p.Teams).Count) {
        $names = (@($p.Teams) | ForEach-Object { $k = $_; ($data.Teams | Where-Object { $_.Key -eq $k }).DisplayName }) -join ', '
        throw "$($p.Name) is still on $names. Take them off their teams first."
    }
    $now = Get-NowLocal
    if ($data.Overrides | Where-Object { $_.PersonId -eq $p.Id -and (ConvertFrom-WallString $_.End) -gt $now }) {
        throw "$($p.Name) has upcoming covers. Delete those first."
    }
    $data.People = @($data.People | Where-Object { $_.Id -ne $p.Id })
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'person_remove' -Detail $p.Name
}

# ---------------------------------------------------------------------------
# Rotations
# ---------------------------------------------------------------------------

function Set-OnCallRotation {
    <#
    .SYNOPSIS
    Sets a team's weekly rotation.
    .PARAMETER Members   People in rotation order (names or Ids). All must be on the team.
    .PARAMETER AnchorStart  A handoff time, e.g. '2026-10-19T08:00' (Monday 8am).
    .PARAMETER AnchorPerson Who is on call starting at AnchorStart.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][string[]]$Members,
        [Parameter(Mandatory)][string]$AnchorStart,
        [Parameter(Mandatory)][string]$AnchorPerson
    )
    $data = Get-ScheduleData
    $team = Resolve-OnCallTeam $data $TeamKey
    $people = foreach ($m in $Members) { Resolve-OnCallPerson $data $m }
    foreach ($p in $people) {
        if (-not (Test-OnTeam $p $TeamKey)) { throw "$($p.Name) isn't on $($team.DisplayName). Add them to the team on the People page first." }
    }
    $ids = @($people.Id)
    if (($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'Someone is in the rotation twice.' }
    $anchorId = (Resolve-OnCallPerson $data $AnchorPerson).Id
    $idx = [array]::IndexOf([string[]]$ids, $anchorId)
    if ($idx -lt 0) { throw "$AnchorPerson is not in the rotation." }

    $data.Rotations[$TeamKey] = @{
        Members     = $ids
        AnchorStart = ConvertTo-WallString (ConvertFrom-WallString $AnchorStart)
        AnchorIndex = $idx
    }
    Save-ScheduleData $data
    $anchorName  = ($people | Where-Object { $_.Id -eq $anchorId }).Name
    Write-OnCallAudit -Event 'rotation_set' -TeamKey $TeamKey -Detail "$(($people.Name) -join ', '). $anchorName on starting $AnchorStart"
}

function Get-OnCallRotation {
    param([Parameter(Mandatory)][string]$TeamKey)
    $data = Get-ScheduleData
    $rot = $data.Rotations[$TeamKey]
    if (-not $rot) { return [pscustomobject]@{ TeamKey = $TeamKey; Members = @(); AnchorStart = $null; AnchorPersonId = $null } }
    [pscustomobject]@{
        TeamKey        = $TeamKey
        Members        = @($rot.Members)
        AnchorStart    = $rot.AnchorStart
        AnchorPersonId = @($rot.Members)[[int]$rot.AnchorIndex]
    }
}

# ---------------------------------------------------------------------------
# Covers (overrides) and swaps
# ---------------------------------------------------------------------------

function New-OverrideRecord {
    param([hashtable]$Data, [string]$TeamKey, $Person, [datetime]$Start, [datetime]$End, [string]$Note, [string]$SwapId)
    @{
        Id         = [guid]::NewGuid().ToString('n').Substring(0, 8)
        TeamKey    = $TeamKey
        PersonId   = $Person.Id
        Start      = ConvertTo-WallString $Start
        End        = ConvertTo-WallString $End
        Note       = $Note
        SwapId     = $SwapId
        CreatedUtc = [datetime]::UtcNow.ToString('o')
        CreatedBy  = if ($script:Actor) { $script:Actor } else { "$env:USERDOMAIN\$env:USERNAME" }
    }
}

function Add-OnCallOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][string]$Person,
        [Parameter(Mandatory)][string]$Start,
        [Parameter(Mandatory)][string]$End,
        [string]$Note
    )
    $data = Get-ScheduleData
    $team = Resolve-OnCallTeam $data $TeamKey
    $p = Resolve-OnCallPerson $data $Person
    if (-not (Test-OnTeam $p $TeamKey)) { throw "$($p.Name) isn't on $($team.DisplayName)." }
    $s = ConvertFrom-WallString $Start
    $e = ConvertFrom-WallString $End
    if ($e -le $s) { throw 'The end has to be after the start.' }

    $o = New-OverrideRecord $data $TeamKey $p $s $e $Note $null
    $data.Overrides = @($data.Overrides) + $o
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'override_add' -TeamKey $TeamKey -Detail "$($p.Name) $($o.Start) to $($o.End) $Note"
    [pscustomobject]$o
}

function Set-OnCallOverride {
    <# Change an existing cover (used by drag and resize on the calendar). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Person, [string]$Start, [string]$End, [string]$Note
    )
    $data = Get-ScheduleData
    $o = $data.Overrides | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $o) { throw "No cover with Id $Id." }
    if ($Person) {
        $p = Resolve-OnCallPerson $data $Person
        if (-not (Test-OnTeam $p $o.TeamKey)) { throw "$($p.Name) isn't on that team." }
        $o.PersonId = $p.Id
    }
    if ($Start)  { $o.Start = ConvertTo-WallString (ConvertFrom-WallString $Start) }
    if ($End)    { $o.End   = ConvertTo-WallString (ConvertFrom-WallString $End) }
    if ($PSBoundParameters.ContainsKey('Note')) { $o.Note = $Note }
    if ((ConvertFrom-WallString $o.End) -le (ConvertFrom-WallString $o.Start)) { throw 'The end has to be after the start.' }
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'override_update' -TeamKey $o.TeamKey -Detail "$($o.Start) to $($o.End) $($o.Note)"
    [pscustomobject]$o
}

function Remove-OnCallOverride {
    <# -WholeSwap also removes the other half of a swap. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [switch]$WholeSwap)
    $data = Get-ScheduleData
    $o = $data.Overrides | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $o) { throw "No cover with Id $Id." }
    $gone = if ($WholeSwap -and $o.SwapId) { @($data.Overrides | Where-Object { $_.SwapId -eq $o.SwapId }) } else { @($o) }
    $ids  = @($gone.Id)
    $data.Overrides = @($data.Overrides | Where-Object { $_.Id -notin $ids })
    Save-ScheduleData $data
    $event = if ($gone.Count -gt 1) { 'swap_remove' } else { 'override_remove' }
    Write-OnCallAudit -Event $event -TeamKey $o.TeamKey -Detail (($gone | ForEach-Object { "$($_.Start) to $($_.End) $($_.Note)" }) -join '; ')
}

function Get-RotationWeek {
    <# The rotation week (handoff to handoff) that contains a moment. #>
    param([hashtable]$Data, [string]$TeamKey, [datetime]$At)
    Get-RotationSlots $Data $TeamKey $At $At.AddMinutes(1) | Select-Object -First 1
}

function Get-OnCallSwapOptions {
    <#
    For swapping the rotation week that contains WeekStart with another person:
    their rotation weeks from 3 months back to a year ahead. The suggested one
    is their first week after the swapped week.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][string]$WeekStart,
        [Parameter(Mandatory)][string]$WithPerson
    )
    $data = Get-ScheduleData
    $team = Resolve-OnCallTeam $data $TeamKey
    $week = Get-RotationWeek $data $TeamKey (ConvertFrom-WallString $WeekStart)
    if (-not $week) { throw "$($team.DisplayName) has no rotation week there." }
    $b = Resolve-OnCallPerson $data $WithPerson
    if ($b.Id -eq $week.PersonId) { throw "That's already $($b.Name)'s week." }
    if (-not (Test-OnTeam $b $TeamKey)) { throw "$($b.Name) isn't on $($team.DisplayName)." }

    $theirs = @(Get-RotationSlots $data $TeamKey $week.Start.AddDays(-91) $week.Start.AddDays(366) |
                Where-Object { $_.PersonId -eq $b.Id })
    $suggest = $theirs | Where-Object { $_.Start -gt $week.Start } | Select-Object -First 1
    [pscustomobject]@{
        TeamKey    = $TeamKey
        WeekStart  = ConvertTo-WallString $week.Start
        WeekEnd    = ConvertTo-WallString $week.End
        FromPerson = $week.PersonName
        WithPerson = $b.Name
        Options    = @($theirs | ForEach-Object {
            $s = $_.Start; $e = $_.End
            [pscustomobject]@{
                Start     = ConvertTo-WallString $s
                End       = ConvertTo-WallString $e
                Suggested = [bool]($suggest -and $s -eq $suggest.Start)
                HasCover  = [bool]($data.Overrides | Where-Object {
                    $_.TeamKey -eq $TeamKey -and (ConvertFrom-WallString $_.Start) -lt $e -and (ConvertFrom-WallString $_.End) -gt $s })
            }
        })
    }
}

function New-OnCallSwap {
    <#
    Swaps two whole rotation weeks: the other person covers this week,
    and this week's person covers the other person's chosen week.
    Creates two linked covers. The rotation itself is not changed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][string]$WeekStart,
        [Parameter(Mandatory)][string]$WithPerson,
        [Parameter(Mandatory)][string]$OtherWeekStart
    )
    $data = Get-ScheduleData
    $team = Resolve-OnCallTeam $data $TeamKey
    $wA = Get-RotationWeek $data $TeamKey (ConvertFrom-WallString $WeekStart)
    $wB = Get-RotationWeek $data $TeamKey (ConvertFrom-WallString $OtherWeekStart)
    if (-not $wA -or -not $wB) { throw "$($team.DisplayName) has no rotation week there." }
    $a = Resolve-OnCallPerson $data $wA.PersonId
    $b = Resolve-OnCallPerson $data $WithPerson
    if ($wB.PersonId -ne $b.Id) { throw "The week of $(Format-Friendly $wB.Start) isn't $($b.Name)'s." }
    if ($a.Id -eq $b.Id) { throw "Both weeks belong to $($a.Name)." }
    if (-not (Test-OnTeam $b $TeamKey)) { throw "$($b.Name) isn't on $($team.DisplayName)." }

    $swapId = [guid]::NewGuid().ToString('n').Substring(0, 8)
    $o1 = New-OverrideRecord $data $TeamKey $b $wA.Start $wA.End "Swap with $($a.Name)" $swapId
    $o2 = New-OverrideRecord $data $TeamKey $a $wB.Start $wB.End "Swap with $($b.Name)" $swapId
    $data.Overrides = @($data.Overrides) + $o1 + $o2
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'swap_add' -TeamKey $TeamKey -Detail (
        "$($b.Name) takes $(Format-Friendly $wA.Start) to $(Format-Friendly $wA.End); " +
        "$($a.Name) takes $(Format-Friendly $wB.Start) to $(Format-Friendly $wB.End)")
    @([pscustomobject]$o1, [pscustomobject]$o2)
}

# ---------------------------------------------------------------------------
# Switches
# ---------------------------------------------------------------------------

function Set-OnCallSwitch {
    <# Turn the whole scheduler, or one team, on or off. #>
    [CmdletBinding(DefaultParameterSetName = 'Global')]
    param(
        [Parameter(ParameterSetName = 'Global', Mandatory)][switch]$Global,
        [Parameter(ParameterSetName = 'Team', Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][bool]$Enabled
    )
    $data = Get-ScheduleData
    if ($Global) { $data.Switches.Global = $Enabled; $what = 'global' }
    else         { $null = Resolve-OnCallTeam $data $TeamKey; $data.Switches.Teams[$TeamKey] = $Enabled; $what = $TeamKey }
    Save-ScheduleData $data
    Write-OnCallAudit -Event 'switch' -TeamKey $(if ($Global) { $null } else { $TeamKey }) -Detail "$what = $Enabled"
}

$script:CheckChoices = 5, 10, 15, 20, 30, 60

function Get-OnCallCheckMinutes { [int](Get-ScheduleData).Settings.CheckMinutes }

function Set-OnCallCheckMinutes {
    <# How often to check Webex, lined up to the top of the hour. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Minutes)
    if ($Minutes -notin $script:CheckChoices) { throw "Pick one of: $($script:CheckChoices -join ', ') minutes." }
    $data = Get-ScheduleData
    $old = [int]$data.Settings.CheckMinutes
    $data.Settings.CheckMinutes = $Minutes
    Save-ScheduleData $data
    if ($old -ne $Minutes) { Write-OnCallAudit -Event 'setting_change' -Detail "Check Webex every $Minutes minutes (was $old)" }
}

function Test-OnCallTeamEnabled {
    param([hashtable]$Data, [string]$TeamKey)
    [bool]$Data.Switches.Global -and [bool]$Data.Switches.Teams[$TeamKey]
}

# ---------------------------------------------------------------------------
# Slots and resolution
# ---------------------------------------------------------------------------

function New-Slot {
    param($TeamKey, $Person, [datetime]$Start, [datetime]$End, [string]$Source, [int]$Priority,
          [string]$OverrideId, [string]$Note, [string]$Created, [string]$SwapId)
    [pscustomobject]@{
        TeamKey    = $TeamKey
        PersonId   = $Person.Id
        PersonName = $Person.Name
        Number     = $Person.Number
        Start      = $Start
        End        = $End
        Source     = $Source
        Priority   = $Priority
        OverrideId = $OverrideId
        SwapId     = $SwapId
        Note       = $Note
        Created    = $Created
    }
}

function Get-RotationSlots {
    param([hashtable]$Data, [string]$TeamKey, [datetime]$From, [datetime]$To)
    $rot = $Data.Rotations[$TeamKey]
    if (-not $rot -or -not $rot.Members -or @($rot.Members).Count -eq 0) { return }

    $members = @($rot.Members)
    $anchor  = ConvertFrom-WallString $rot.AnchorStart
    $n       = $members.Count
    $first   = [math]::Floor(($From - $anchor).TotalDays / 7)
    $last    = [math]::Floor(($To   - $anchor).TotalDays / 7)

    for ($w = $first; $w -le $last; $w++) {
        $s   = $anchor.AddDays(7 * $w)
        $e   = $s.AddDays(7)
        if ($e -le $From -or $s -ge $To) { continue }
        $idx = ((([int]$rot.AnchorIndex + $w) % $n) + $n) % $n
        $personId = $members[$idx]
        $p = $Data.People | Where-Object { $_.Id -eq $personId } | Select-Object -First 1
        if (-not $p) { $p = @{ Id = $personId; Name = "(missing $personId)"; Number = $null } }
        New-Slot -TeamKey $TeamKey -Person $p -Start $s -End $e -Source 'Rotation' -Priority 10
    }
}

function Get-OverrideSlots {
    param([hashtable]$Data, [string]$TeamKey, [datetime]$From, [datetime]$To)
    foreach ($o in $Data.Overrides) {
        if ($o.TeamKey -ne $TeamKey) { continue }
        $s = ConvertFrom-WallString $o.Start
        $e = ConvertFrom-WallString $o.End
        if ($e -le $From -or $s -ge $To) { continue }
        $p = $Data.People | Where-Object { $_.Id -eq $o.PersonId } | Select-Object -First 1
        if (-not $p) { $p = @{ Id = $o.PersonId; Name = "(missing $($o.PersonId))"; Number = $null } }
        New-Slot -TeamKey $TeamKey -Person $p -Start $s -End $e -Source 'Override' -Priority 20 `
                 -OverrideId $o.Id -Note $o.Note -Created $o.CreatedUtc -SwapId $o.SwapId
    }
}

function Get-OnCallSlots {
    <#
    .SYNOPSIS
    All schedule slots for a team that overlap From..To (Pacific wall-clock).
    This is what the calendar view will draw.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [Parameter(Mandatory)][datetime]$From,
        [Parameter(Mandatory)][datetime]$To
    )
    $data = Get-ScheduleData
    $f = ConvertTo-ScheduleLocal $From
    $t = ConvertTo-ScheduleLocal $To
    @(Get-RotationSlots $data $TeamKey $f $t) + @(Get-OverrideSlots $data $TeamKey $f $t) |
        Sort-Object Start, Priority
}

function Get-OnCallAssignment {
    <#
    .SYNOPSIS
    Who should be on call for a team at a moment. Highest priority slot wins;
    among overlapping covers, the most recently created wins.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamKey,
        [datetime]$At = [datetime]::UtcNow
    )
    $local = ConvertTo-ScheduleLocal $At
    $win = Get-OnCallSlots -TeamKey $TeamKey -From $local -To $local.AddMinutes(1) |
        Where-Object { $_.Start -le $local -and $_.End -gt $local } |
        Sort-Object @{ e = 'Priority'; Descending = $true }, @{ e = 'Created'; Descending = $true } |
        Select-Object -First 1

    if (-not $win) {
        return [pscustomobject]@{ TeamKey = $TeamKey; At = $local; Source = 'None'; PersonName = $null; Number = $null }
    }

    # When this assignment really ends: its own end, or earlier if an equal or
    # higher priority slot (a cover) starts before then.
    $cut = Get-OnCallSlots -TeamKey $TeamKey -From $local -To $win.End |
        Where-Object { $_.Start -gt $local -and $_.Start -lt $win.End -and $_.Priority -ge $win.Priority } |
        Sort-Object Start | Select-Object -First 1
    $effEnd = if ($cut) { $cut.Start } else { $win.End }

    $win | Add-Member -NotePropertyName At -NotePropertyValue $local -PassThru |
           Add-Member -NotePropertyName EffectiveEnd -NotePropertyValue $effEnd -PassThru
}

# ---------------------------------------------------------------------------
# Audit and runtime state
# ---------------------------------------------------------------------------

function Write-OnCallAudit {
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$TeamKey, [string]$Old, [string]$New, [string]$Person, [string]$Source,
        [string]$Detail, [string]$Actor
    )
    if (-not $Actor) { $Actor = if ($script:Actor) { $script:Actor } else { "$env:USERDOMAIN\$env:USERNAME" } }
    $line = [ordered]@{
        Ts = [datetime]::UtcNow.ToString('o'); Event = $Event; Actor = $Actor; TeamKey = $TeamKey
        Old = $Old; New = $New; Person = $Person; Source = $Source; Detail = $Detail
    } | ConvertTo-Json -Compress
    Add-Content -LiteralPath (Get-SchedulePath 'audit.jsonl') -Value $line -Encoding utf8
}

function Set-OnCallActor {
    <# Label for audit entries made from this runspace, e.g. 'web'. #>
    param([string]$Name)
    $script:Actor = $Name
}

function Get-OnCallAudit {
    param([int]$Last = 50)
    $f = Get-SchedulePath 'audit.jsonl'
    if (-not (Test-Path -LiteralPath $f)) { return }
    Get-Content -LiteralPath $f -Tail $Last | ForEach-Object { $_ | ConvertFrom-Json }
}

function Get-OnCallRuntime {
    $f = Get-SchedulePath 'runtime.json'
    if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable }
    else { @{ LastApplied = @{} } }
}

# ---------------------------------------------------------------------------
# Sync
# ---------------------------------------------------------------------------

function Get-OnCallSyncPlan {
    <#
    .SYNOPSIS
    Read-only. For every team, compares who should be on call with what Webex has now.
    Action: Change, InSync, Disabled, NoSchedule, NoNumber, Error
    #>
    [CmdletBinding()]
    param([datetime]$At = [datetime]::UtcNow)

    $data = Get-ScheduleData
    foreach ($t in $data.Teams) {
        $a = Get-OnCallAssignment -TeamKey $t.Key -At $At
        $row = [ordered]@{
            TeamKey = $t.Key; Enabled = (Test-OnCallTeamEnabled $data $t.Key)
            Person = $a.PersonName; Source = $a.Source; Note = $a.Note
            Desired = $a.Number; Current = $null; Action = $null; Error = $null
        }
        try {
            $row.Current = (Get-WebexTeam -TeamId $t.WebexTeamId).DialedNumber
            $row.Action = if ($a.Source -eq 'None')        { 'NoSchedule' }
                          elseif (-not $a.Number)           { 'NoNumber' }
                          elseif ($row.Current -eq $a.Number) { 'InSync' }
                          elseif (-not $row.Enabled)        { 'Disabled' }
                          else                              { 'Change' }
        }
        catch { $row.Action = 'Error'; $row.Error = $_.Exception.Message }
        [pscustomobject]$row
    }
}

function Invoke-OnCallSync {
    <#
    .SYNOPSIS
    Applies the sync plan: sets Webex for every enabled team that is out of sync.
    Supports -WhatIf. Writes every change and error to the audit log.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([datetime]$At = [datetime]::UtcNow, [string]$Actor = 'scheduler')

    $runtime = Get-OnCallRuntime
    if (-not $runtime.LastApplied) { $runtime.LastApplied = @{} }
    $teams   = (Get-ScheduleData).Teams
    $plan    = Get-OnCallSyncPlan -At $At

    foreach ($row in $plan) {
        if ($row.Action -eq 'Error') {
            Write-OnCallAudit -Event 'sync_error' -TeamKey $row.TeamKey -Detail $row.Error -Actor $Actor
            continue
        }
        if ($row.Action -ne 'Change') { continue }

        $last    = $runtime.LastApplied[$row.TeamKey]
        $outside = [bool]($last -and $row.Current -ne $last)
        $team    = $teams | Where-Object { $_.Key -eq $row.TeamKey }

        if (-not $PSCmdlet.ShouldProcess($row.TeamKey, "Set $($row.Current) -> $($row.Desired) ($($row.Person), $($row.Source))")) {
            continue
        }
        try {
            $r = Set-WebexTeamDialNumber -TeamId $team.WebexTeamId -DialNumber $row.Desired -Confirm:$false
            $runtime.LastApplied[$row.TeamKey] = $row.Desired
            $parts  = @($row.Note, $(if ($outside) { 'outside change reverted' })) | Where-Object { $_ }
            $detail = $parts -join '; '
            Write-OnCallAudit -Event 'number_change' -TeamKey $row.TeamKey -Old $r.Previous -New $row.Desired `
                              -Person $row.Person -Source $row.Source -Detail $detail -Actor $Actor
        }
        catch {
            Write-OnCallAudit -Event 'sync_error' -TeamKey $row.TeamKey -Detail $_.Exception.Message -Actor $Actor
        }
    }
    $runtime.LastRunUtc = [datetime]::UtcNow.ToString('o')
    $runtime.LastActor  = $Actor
    Save-JsonAtomic -Path (Get-SchedulePath 'runtime.json') -Object $runtime
}

function Invoke-OnCallTick {
    <#
    Runs every minute. Talks to Webex only when:
      - the check interval lines up (for 30: at :00 and :30), or
      - the last check is older than the interval (after a restart or outage), or
      - who should be on call just changed (a handoff, or a cover starting or ending).
    The last one is worked out from the schedule alone, so it costs nothing.
    #>
    [CmdletBinding()]
    param([string]$Actor = 'scheduler')

    $data     = Get-ScheduleData
    $interval = [int]$data.Settings.CheckMinutes
    $now      = Get-NowLocal
    $runtime  = Get-OnCallRuntime

    $desired = @{}
    foreach ($t in $data.Teams) { $desired[$t.Key] = "$((Get-OnCallAssignment -TeamKey $t.Key).Number)" }
    $before  = if ($runtime.LastDesired) { $runtime.LastDesired } else { @{} }
    $changed = @($desired.Keys | Where-Object { $desired[$_] -ne "$($before[$_])" })

    $aligned = (($now.Hour * 60 + $now.Minute) % $interval) -eq 0
    $last = $runtime.LastRunUtc
    if ($last -and $last -isnot [datetime]) {
        $last = [datetime]::Parse([string]$last, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    }
    $stale = -not $last -or ([datetime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -ge $interval

    if ($aligned -or $stale -or $changed) {
        Invoke-OnCallSync -Actor $Actor
        $runtime = Get-OnCallRuntime   # the sync saved its own fields
    }
    $runtime.LastDesired = $desired
    Save-JsonAtomic -Path (Get-SchedulePath 'runtime.json') -Object $runtime
}

Export-ModuleMember -Function Invoke-OnCallTick, Get-OnCallCheckMinutes, Set-OnCallCheckMinutes,
    Initialize-ScheduleModule, Get-ScheduleData, Save-ScheduleData,
    ConvertTo-ScheduleLocal,
    Get-OnCallTeams, Add-OnCallTeam, Set-OnCallTeam, Remove-OnCallTeam,
    Get-OnCallPerson, Add-OnCallPerson, Set-OnCallPerson, Remove-OnCallPerson,
    Get-OnCallRotation, Set-OnCallRotation,
    Add-OnCallOverride, Set-OnCallOverride, Remove-OnCallOverride,
    Get-OnCallSwapOptions, New-OnCallSwap,
    Set-OnCallSwitch,
    Get-OnCallSlots, Get-OnCallAssignment, Get-OnCallSyncPlan, Invoke-OnCallSync,
    Write-OnCallAudit, Get-OnCallAudit, Get-OnCallRuntime, Set-OnCallActor
