# On-Call Manager

Switches the on-call forwarding number on Webex Contact Center teams from a weekly rotation
plus one-off covers and week swaps. PowerShell 7 and Pode, with a web UI for the schedule.

Runs on Windows or Linux, directly or in a container:

| | Directly | Container |
|---|---|---|
| Windows | scheduled task (`Install-OnCall.ps1`) | Docker Desktop, Linux image |
| Linux | systemd user service (`Install-OnCall.ps1`) | Docker or Podman |

Nothing needs admin or root.

## What you need from Webex

1. **A Service App** with `cjp:config_read` and `cjp:config_write`, authorized by a full
   admin in Control Hub. Its client ID, client secret and refresh token go on the Settings
   page. The app renews the token daily, so it doesn't expire.
2. **Your org ID** (Control Hub, Account) and **Contact Center region** (us1, eu1, ...).
3. **Each team's ID** (Contact Center, Teams). You add teams on the Teams page.
4. **Network mode only:** a Webex **Integration** with the `spark:people_read` scope, used for
   "Sign in with Webex". Its redirect URI is `<your URL>/auth/callback`.

## Two ways to listen

**Local** (default): `http://localhost:8080`, no sign-in. Only the computer running it can open
the page.

**Network**: HTTPS on every interface (default port 8443). Everyone signs in with Webex, and
only people in your Webex org whose email is on the list in Settings get in. The first start
prints a one-time setup code; open `<your URL>/setup`, enter it with the Integration keys and
your email, then sign in.

The certificate is self-signed unless you provide one (`ONCALL_CERT_FILE` and
`ONCALL_KEY_FILE` as PEM, or a `.pfx` with `ONCALL_CERT_PASSWORD`). Browsers warn about a
self-signed cert, so use one from your own CA for anything shared.

## Run it directly (Windows or Linux)

1. Install [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell)
   and Pode: `Install-Module Pode -Scope CurrentUser`
2. On Windows, unblock the files after extracting: `Get-ChildItem . -Recurse | Unblock-File`
3. Try it in a console:
   - `./Start-OnCall.ps1` (Local), or
   - `./Start-OnCall.ps1 -Listen Network -PublicUrl https://oncall.example.com:8443`
4. Open the page, then go to **Settings**: org ID, region, time zone, then the Service App keys.
5. Keep it running: `./Install-OnCall.ps1` with the same `-Listen`/`-PublicUrl`.
   - Windows: a scheduled task as you, running whether or not you're signed in, back within
     5 minutes of a reboot. Use `-WhenLoggedOn` if your account can't run tasks while signed out.
   - Linux: a systemd user service plus linger, so it runs while you're signed out. Logs with
     `journalctl --user -u oncall.service`.
   - `./Install-OnCall.ps1 -Remove` undoes either one.

## Run it in a container

```bash
openssl rand -base64 48 > master.key
```

Keep a copy of `master.key` somewhere safe. It encrypts the keys you save on Settings; lose it
and you re-enter them.

Edit `ONCALL_PUBLIC_URL` in `docker-compose.yml` to the address people will use, then:

```bash
docker compose up -d
```

```bash
docker compose logs
```

The log shows the setup code. Everything lives in the `oncall-data` volume (`/app/data`), so
rebuilding or updating the image keeps your schedule and keys. The container runs as user
10001; to use a host folder instead of the volume, `chown 10001` it first (see the comment in
`docker-compose.yml`). The image refuses to start without the `oncall_master_key` secret.

On Docker Desktop for Windows or macOS the same compose file works.

## How keys are protected

| Setup | Method | Stored in |
|---|---|---|
| `ONCALL_MASTER_KEY_FILE` set, or Docker secret `oncall_master_key` | AES-256-GCM with that key | `data/secrets.json`, `data/login.json` |
| Windows, no master key | DPAPI, only the Windows account that saved them can read them | `data/secrets.clixml`, `data/login.clixml` |
| Linux/macOS, no master key | AES-256-GCM, key generated in `~/.config/oncall/master.key` | `data/secrets.json`, `data/login.json` |

Settings shows which one is in use. If the saved keys can't be read (wrong master key,
different Windows account), the app says so and you can enter them again on Settings.

## Settings by environment variable

| Variable | Default | What |
|---|---|---|
| `ONCALL_LISTEN` | `Local` | `Local` or `Network` (same as `-Listen`) |
| `ONCALL_PORT` | 8080 / 8443 | Port (same as `-Port`) |
| `ONCALL_PUBLIC_URL` | `https://localhost:<port>` | Address people use; sets the redirect URI and allowed Host |
| `ONCALL_DATA` | `./data` | Data folder |
| `ONCALL_MASTER_KEY_FILE` | | Master key file (overrides DPAPI and the generated key) |
| `ONCALL_CERT_FILE`, `ONCALL_KEY_FILE`, `ONCALL_CERT_PASSWORD` | `data/tls/` | Your HTTPS certificate |

## Updating

1. Download `OnCall-x.y.z.zip` from the Releases page (or pull and rebuild the image).
2. Stop the app, extract over the old folder (`Unblock-File` again on Windows), start it.
   Settings shows the running version.

Code updates never include `data/`, so your keys and schedule stay. Changes per version are in
`CHANGELOG.md`.

## Files

| Path | What |
|---|---|
| `data/config.json` | Org ID, region, time zone (edited from Settings; see `config.example.json`) |
| `data/schedule.json` | Teams, people, rotations, covers, switches, sign-in list |
| `data/secrets.*`, `data/login.*` | Encrypted Webex keys (see above) |
| `data/tls/` | Self-signed certificate (network mode) |
| `data/audit.jsonl` | Everything that changed and who did it, one line each |
| `logs/` | Server error log |

## How switching works

The app checks Webex on the interval set in Settings (default every 30 minutes, on the hour
and half hour). Separately, every minute it looks at its own schedule, which never touches
Webex, and switches right away when a handoff or cover starts or ends. When a team is out of
sync and switching is on for it, the app updates that team's `dialedNumber`, changing nothing
else, and logs it. A cover wins over the rotation. Times follow the time zone in Settings
(default: the computer's own).

## Testing

`tests/mock_webex.py` stands in for Webex (token, config-service, sign-in). With it running,
`tests/Smoke.ps1` starts the real server in both modes and checks the main flows. CI runs it
on Windows and Linux and builds the container image.
