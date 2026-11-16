# Changelog

Versions follow [Semantic Versioning](https://semver.org/): patch for fixes, minor for
features, major for changes that need `data\` or config edited by hand.

## [Unreleased]

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

[Unreleased]: https://github.com/Crolton1986/WxOnCallChanger/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/Crolton1986/WxOnCallChanger/releases/tag/v0.9.0
