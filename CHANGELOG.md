# Changelog

Versions follow [Semantic Versioning](https://semver.org/): patch for fixes, minor for
features, major for changes that need `data\` or config edited by hand.

## [Unreleased]

## [0.10.0] - 2026-11-20

### Added
- Runs on Linux as well as Windows, directly or in a container. `Dockerfile` and
  `docker-compose.yml` for a Linux image.
- Network mode (`-Listen Network`): HTTPS on all interfaces with "Sign in with Webex". Only
  people in the configured Webex org and on the sign-in list in Settings get in. Self-signed
  certificate unless you provide one.
- One-time setup page for network mode, unlocked by a code printed at startup.
- Settings: org ID, Contact Center region, schedule time zone, sign-in list, sign-in
  Integration keys, and how keys are protected.
- Keys can be encrypted with a master key file (AES-256-GCM) on any platform; Linux generates
  one in `~/.config/oncall` when none is given. Windows still uses DPAPI by default.
- `Install-OnCall.ps1` sets up a systemd user service on Linux.
- `tests/Smoke.ps1` and a CI workflow running it on Windows and Linux, plus an image build.
- History records who made each change (signed-in email in network mode).

### Changed
- The schedule time zone defaults to the computer's own zone instead of US Pacific. Set it on
  Settings (or keep `TimeZone` in `config.json`) if that's not what you want.
- `config.json` is created with defaults on first start; `config.example.json` shows its shape.
- Removed organization-specific names, IDs and sample people.

### Fixed
- A config.json without `Teams` no longer creates a blank team on first start.

## [0.9.0] - 2026-11-16

First tagged build. Done and tested against the mock Webex server; not yet proven on a live team.

### Added
- Webex module: Service App token refresh (DPAPI-protected keys), GET/PUT of a team's `dialedNumber` with one retry on 401.
- Schedule engine: weekly rotations, covers (newest wins), week swaps, per-team and global switches, audit log.
- Web UI: Now, Calendar with rotation editor, People, Teams, History, Settings.
- Team management with Webex team ID check, check interval setting, credential replace from Settings.
- `Install-OnCall.ps1` scheduled task as the current user with a 5-minute watchdog trigger.
- `tests/mock_webex.py` stand-in for the Webex token and config-service endpoints.
- Version shown on the Settings page and in the startup line.

### Changed
- Logging uses `New-PodeLogFileMethod` instead of the deprecated `New-PodeLoggingMethod`.

### Not yet verified live
- A switch on a real team, `Install-OnCall.ps1` on Windows, Pode from PSGallery on Windows,
  the first Monday 8am handoff, real phone numbers and rotation order.

[Unreleased]: https://github.com/Crolton1986/WxOnCallChanger/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/Crolton1986/WxOnCallChanger/releases/tag/v0.10.0
[0.9.0]: https://github.com/Crolton1986/WxOnCallChanger/releases/tag/v0.9.0
