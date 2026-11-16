# On-Call Manager

Switches the on-call forwarding number on Webex Contact Center teams at AllCare Health from a
weekly rotation plus one-off covers and week swaps. PowerShell 7 + Pode web UI on
http://localhost:8080. Replaces the manual `ACH_OnCall_Manager.ps1` script and an earlier
containerized Node app (the container was a poor fit for always-on scheduling).

## Hard requirements (from the owner)

- PowerShell 7 only (`#Requires -Version 7.4`). Never target 5.1.
- Never require admin. Installs go to the user profile (`Install-Module -Scope CurrentUser`).
  The scheduled task runs as the user, created without elevation.
- Local only for now (binds `localhost`). Runs whether or not anyone is signed in.
- Code updates ship without `data\`, so updating never touches keys or the schedule.
- Ask before building when a requirement is ambiguous. The owner prefers short answers and
  confirming assumptions first.

## Layout

```
Start-OnCall.ps1      Pode server: routes, minute tick. -Service runs as a daemon (no console).
Install-OnCall.ps1    Registers the scheduled task as the current user. -WhenLoggedOn, -Remove.
Test-Webex.ps1        -SetupCredential stores Service App keys. Read-only team check by default.
VERSION               Current version (semver, no leading v). Shown in Settings.
CHANGELOG.md          One entry per release; the release workflow uses it for notes.
Test-Schedule.ps1     Prints who is on now, the next 3 weeks, and a read-only sync preview.
modules\Webex.psm1    Token handling + config-service GET/PUT of a team's dialedNumber.
modules\Schedule.psm1 Teams, people, rotations, covers, swaps, switches, resolution, sync, audit.
modules\Web.psm1      Shapes data for the API; Invoke-OnCallApi wraps every route.
tests\mock_webex.py   Python stand-in for the Webex token + config-service endpoints.
public\               index.html, app.js, app.css, vendor\fullcalendar.min.js (6.1.22, MIT).
.github\workflows\    release.yml: on a v* tag, builds OnCall-x.y.z.zip and the GitHub release.
data\                 (not shipped) config.json, schedule.json, secrets.clixml, audit.jsonl, runtime.json
```

## How it works

- **Webex auth:** Webex Service App with `cjp:config_read` and `cjp:config_write`, authorized in
  Control Hub. Client ID, secret and refresh token are stored in `data\secrets.clixml` via
  DPAPI, so only the Windows account that saved them can read them. The access token is
  refreshed when it's under 1 hour from expiry and at least daily. Each refresh resets the
  refresh token's 90-day life (per Cisco staff on the developer forum; the reset can lag a few
  days). Keys can be replaced from the Settings page, and a failed test restores the old keys.
  A named mutex serializes all reads and writes of the keys file.
- **Team update:** GET `{ConfigBaseUrl}/cms/api/organization/{OrgId}/team/{TeamId}`, change only
  `dialedNumber`, PUT the whole object back. Uses System.Text.Json so other fields round-trip
  untouched. Retries once on 401. Numbers are normalized to digits, 7 to 15 long, and a
  10-digit number gets a leading 1.
- **Schedule resolution:** sources produce slots (team, person, start, end, priority).
  Rotation = priority 10 (weekly, from an anchor handoff + anchor person; default Monday 8am).
  Covers = priority 20; among overlapping covers the newest wins. A swap is two linked
  full-week covers sharing a `SwapId`. All times are Pacific wall clock strings
  (`yyyy-MM-ddTHH:mm`); DST is handled through TimeZoneInfo.
- **Switching:** Pode schedule ticks every minute (`Invoke-OnCallTick`). It calls Webex only when
  the interval from Settings lines up (default 30 min, at :00 and :30), the last check is
  overdue, or the desired number changed (handoff or cover boundary, computed locally). A
  change happens only if the global switch and that team's switch are both on. Outside edits
  in Control Hub are reverted at the next check and logged.
- **Teams:** live in `schedule.json` (migrated once from `config.json`). Each has a Webex team
  UUID, checked against Webex when saved, and a color index 0-7 (`tc-N` in CSS).
- **People:** name, number, list of teams. Being on a team only makes someone available.
  Rotation order is set on the Calendar page.
- **Removal rules:** a team can't be removed while it has people or covers ending after now.
  Taking someone off a team is blocked if they have future covers on it; otherwise they're
  pulled from its rotation, the current week stays put, and later weeks shift.
- **API guard:** Host header must be localhost; every write under `/api/` needs the
  `X-OnCall: 1` header (blocks cross-site posts). Writes run inside `Lock-PodeObject`.

## Branches and releases

- `main` is always releasable. Never commit to it directly: work on a branch, open a PR into
  `main`, merge it.
- Semver: patch for fixes, minor for features, major when `data\` or config needs hand edits.
- To release: on the branch, bump `VERSION` and move `[Unreleased]` notes into a new
  `## [x.y.z] - date` section of `CHANGELOG.md` (update the compare links at the bottom).
  After the PR merges, tag the merge commit on `main` with `git tag -a vx.y.z -m vx.y.z` and
  push the tag. The workflow fails if `VERSION` doesn't match the tag or the changelog has no
  entry, then builds the zip with `git archive` (`.gitattributes` keeps tests, `.github` and
  this file out) and attaches it to the release. A tag with `-` (`v1.0.0-rc.1`) is a prerelease.
- Plan: v1.0.0 once the first live Monday handoff works.

## Gotchas already hit (don't relearn these)

- `Start-PodeServer -Daemon` needs `-ScriptBlock` passed by name.
- `$using:` doesn't work at the top level of the Pode server block. Values go through `$env:ONCALL_*`.
- Pode's JSON body parser turns `2026-10-19T08:00:00` into a DateTime, and binding that to a
  `[string]` param gives `10/19/2026 08:00:00`. `ConvertFrom-WallString` accepts both shapes.
- `@($null).Count` is 1. Filter with `Where-Object { $_ }` before counting.
- `$out[-1]` on a hashtable looks up key -1. Use `$out[$out.Count - 1]`.
- `$pid` is reserved in PowerShell. Don't use it as a variable name.
- A boot trigger needs admin, so the task uses a repeating 5-minute trigger with
  `MultipleInstances IgnoreNew` as a watchdog instead.
- Files extracted from a downloaded zip need `Unblock-File` under RemoteSigned.

## Testing

No Pester suite yet. Testing so far ran PowerShell 7.4 on Linux against `tests\mock_webex.py`
(stand-in for the token endpoint and config-service), with a source build of Pode 2.14.1, and drove the UI
with Playwright. The mock already covers 401 retry, invalid_client, invalid_grant, 404 team and
per-team numbers, so it's a ready base for real tests.

## Status

Done and tested against the mock: Webex module, schedule engine, web UI (Now, Calendar with
rotation editor, People, Teams, History, Settings), covers, week swaps, team management, check
interval, credential updates.

Verified on the owner's PC: token setup, reading both real teams, Unblock-File flow.

Not yet verified for real:
1. A live switch on a real team (turn switching on, add a short cover, confirm the phone rings).
2. `Install-OnCall.ps1` on Windows (never run). Check the "Log on as a batch job" right;
   `-WhenLoggedOn` is the fallback.
3. Real Pode from PSGallery on Windows (tests used a source build).
4. The first live Monday 8am handoff.
5. Real phone numbers and rotation order (the data still has sample 555 numbers).

## v2

- **Network access with AD login:** a Settings toggle to listen beyond localhost, with Pode
  Windows/AD auth limited to an AD group. Needs a firewall rule and likely a URL reservation,
  so it's opt-in.
- **Outlook calendar as a schedule source:** read the team's Outlook on-call calendar through
  Microsoft Graph and return slots in the same shape as rotation and covers. Decide on a title
  convention ("Support On-Call: Name") and whether Outlook replaces or sits alongside the
  built-in schedule.
- **Freeze past weeks:** store rotation versions with effective dates, so editing a rotation
  doesn't redraw who was on call in past weeks.
- **Unavailable periods:** mark a person out on a team between dates. Options discussed: give
  their week to the next person without shifting anyone else (preferred), flag it as needing
  a cover, or skip and shift everyone.
- **Tests:** Pester tests for the schedule engine plus the mock Webex server.
