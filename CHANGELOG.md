# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Achievements: 50 of them, most with bronze to legendary tiers, judged on the usage history, on the limits (reaching 100 %, saved by the bell, a week ended without a crumb left…) and a few secrets. A notification and a dot announce new ones; the history's are announced together.
- A Statistics window (from the panel or the right-click menu): tokens and API-equivalent cost by day, hour, weekday, project, model, effort and session, a year of activity, streaks, and what your plan's current week would cost through the API. The panel shows today's tokens under Claude and Codex.
- A local usage history: tokens, an API-equivalent cost estimate, projects, models and sessions read from Claude Code's and Codex's own logs, kept by the app so it outlives their cleanup. `--print --stats` prints it.
- When Codex cannot be reached, its quota comes from the windows it last wrote in its logs.
- English, alongside Spanish: the app follows the Mac's language, and dates and numbers its region.
- Settings › Alerts says when macOS blocks the app's notifications or keeps them off screen, with a button to fix it.
- Renewals of Claude Code's session are written to the system log.

### Changed

- After a 429, a service is asked again when its `Retry-After` says, or after 5 minutes (it was always 10).

### Fixed

- Big token figures in Spanish read "3,1 mil M" instead of macOS's "3056,8 M".
- Quitting Antigravity could leave the panel loading for good and stop every other service from refreshing: each service now has a deadline, and `lsof` no longer touches mounted volumes.
- Saving a renewed Claude Code session could truncate its Keychain item when it also held MCP logins, signing Claude Code out.
- The panel showed a square shadow behind its rounded corners.
- Cursor's legacy usage endpoint now shows fast requests as the plan's figure.

## [1.0] - 2026-10-22

First version: Claude, ChatGPT/Codex, Antigravity and Cursor in the menu bar, with a Liquid Glass panel, alerts, weekly pace, a 7-day history and open at login.
