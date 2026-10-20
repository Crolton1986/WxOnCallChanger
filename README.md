# On-Call Manager

Switches the on-call number on Webex Contact Center teams (Support, Systems) from a weekly
rotation plus one-off covers. Web UI at http://localhost:8080. PowerShell 7 and Pode.

## First-time setup

1. Unblock the files after extracting:
   `Get-ChildItem . -Recurse | Unblock-File`
2. Store the Webex Service App keys, signed in as the account that will run it:
   `.\Test-Webex.ps1 -SetupCredential`

## Run it

- Try it in a console: `.\Start-OnCall.ps1` (install Pode first with `Install-Module Pode -Scope CurrentUser`) and open http://localhost:8080. Ctrl+C stops it.
- Keep it running (normal PowerShell 7, no admin): `.\Install-OnCall.ps1`
  It installs Pode into your profile if needed, then registers a task as you that runs
  whether or not you're signed in and comes back within 5 minutes after a reboot.
  Use `-WhenLoggedOn` if your account can't run tasks while signed out.
  Remove it with `.\Install-OnCall.ps1 -Remove`.

Nothing in this app needs admin. The Webex keys are encrypted to the account that saved
them (step 2), so the task runs as that same account.

## Folders

| Path | What |
|---|---|
| `data\config.json` | Org ID, team IDs, time zone |
| `data\schedule.json` | People, rotations, covers, on/off switches (edited from the UI) |
| `data\secrets.clixml` | Webex keys, encrypted to one Windows account |
| `data\audit.jsonl` | Everything that changed, one line each |
| `logs\` | Server error log |

Code updates ship without the `data` folder, so extracting a new version never touches
your keys or schedule.

## How switching works

The app checks Webex on the interval set in Settings (default every 30 minutes, on the hour
and half hour). Separately, every minute it looks at its own schedule, which never touches
Webex, and switches right away when a handoff or cover starts or ends. When a team is out of
sync and switching is on for it, the app updates that team's `dialedNumber`, changing
nothing else, and logs it. A cover wins over the rotation.
