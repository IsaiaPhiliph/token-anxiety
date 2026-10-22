# Token Anxiety

A macOS menu bar app (AppKit + SwiftUI, macOS 26+, Swift 6 language mode) that shows the five-hour and weekly usage of the user's AI plans. The user speaks Spanish: UI text and README are in Spanish; commit messages, code, comments and this file are in English. The code lives in the private GitHub repo `IsaiaPhiliph/token-anxiety`.

## Layout

- `Sources/TokenAnxietyCore`: everything testable without a window.
  - `Providers/`: one actor per service, conforming to `UsageProvider` (`isInstalled()`, `fetch() -> ProviderSnapshot`). Each has static parsers (`snapshot(...)`) that the tests feed with sample JSON.
  - `Models.swift`: `ProviderSnapshot` (`primary` is the five-hour figure, `secondary` the week), `UsageWindow`, `ProviderError` (Spanish messages; `needsUser` errors are not auto-retried).
  - `Pace.swift`, `History.swift` (`HistoryLog`, `AlertTracker`), `Formatting.swift` (`Fmt`, Spanish formats), `Demo.swift` (`--demo` data).
- `Sources/TokenAnxiety`: the app. `UsageStore` polls the providers, `StatusItemController` + `MenuBarRenderer` draw the status item, `PanelController` hosts `PanelView` in a borderless `NSGlassEffectView` panel, `Views/SettingsView` is the settings window.
- `scripts/build-app.sh` assembles and ad-hoc signs `build/Token Anxiety.app` (`--open [args]`, `--install`, `CONFIG=debug`). `scripts/make-icon.swift` draws the icon. `scripts/backdrop.swift` puts a plain gradient behind the panel for screenshots.

## Commands

- `swift build`, `swift test` (Swift Testing, runs in milliseconds).
- `CONFIG=debug scripts/build-app.sh --open --demo --open-panel` to look at the UI with sample data.
- `"build/Token Anxiety.app/Contents/MacOS/TokenAnxiety" --print --debug`: fetches every provider once against the real services and prints figures and steps. Never log tokens, emails or other secrets in `Log.debug`.

## Data sources and pitfalls

- **Claude**: Keychain item `Claude Code-credentials` (JSON, `claudeAiOauth`) read with `/usr/bin/security`, which the item trusts (no prompt). `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`. Access tokens last 8 h. Renewal (the user consented; setting `renewClaudeSession`): refresh grant with Claude Code's client id at `console.anthropic.com` / `platform.claude.com`, then write back the whole JSON with `security -i` on stdin (keeps the secret out of `ps`; `-i` does not report failures, so the write is read back and compared byte for byte). `security -i` reads 4095-byte lines and runs a longer one in pieces, the first of which saves a truncated item; the item also holds Claude Code's MCP logins (5.6 KB on the user's Mac), so a payload that does not fit goes as arguments (`ClaudeProvider.keychainWrite`). Renewals and their failures also go to the system log: `log show --predicate 'subsystem == "com.tokenanxiety.app"' --last 1d`. Only one renewal at a time, and a refused refresh token is never retried: reusing a rotated token can sign Claude Code out.
- **Codex**: `codex app-server` over stdio, newline-delimited JSON-RPC without the `jsonrpc` field: `initialize`, `initialized`, `account/read`, `account/rateLimits/read`, `account/usage/read`. Prefer `/Applications/Codex.app/Contents/Resources/codex` (kept up to date by the desktop app). `codex app-server generate-json-schema --out DIR` prints the protocol. Free plans have a monthly window.
- **Antigravity**: its `language_server_macos*` process has `--csrf_token` on its command line; find its ports with `lsof`, POST `GetUserStatus` (Connect JSON, self-signed TLS on 127.0.0.1). Proto JSON omits zero values: no `remainingFraction` means 0 left. Several servers can run; variants like "(Low)/(High)" share one quota.
- **Cursor**: `state.vscdb` (SQLite). With Cursor closed a read-only WAL open fails with SQLITE_CANTOPEN; it is retried with `immutable=1`. Usage: `cursor.com/api/usage-summary` with cookie `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>` (amounts in cents).

## Checking the UI

`screencapture -l <windowID>` renders glass windows blank; capture a screen region with `screencapture -R x,y,w,h` instead (window bounds from `CGWindowListCopyWindowInfo`). The panel closes on any click outside it, so capture right after `--open-panel`. A Settings window opened from the background stays behind the frontmost app; it is not glass, so `-l` captures it.

README screenshots (`docs/panel-dark.png`, `docs/panel-light.png`): `--demo --open-panel` over `scripts/backdrop.swift dark|light`, captured from y=0 to the panel's bottom, with the other apps' status items in the strip painted over. macOS 26 takes the menu bar's appearance from the wallpaper, not from light/dark mode: on this Mac the status item stays white in light mode, like the system's own items.
