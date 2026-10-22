# Contributing to Token Anxiety

Thanks for helping. Bug reports, fixes, translations and new services are all welcome.

## Before you start

- For anything bigger than a small fix, open an issue first so we can agree on the approach.
- Be kind: this project follows a [code of conduct](CODE_OF_CONDUCT.md).
- Never paste tokens, cookies, emails or other personal data into issues, logs, tests or screenshots. `--print --debug` output is safe to share: it never prints secrets.

## Setup

You need macOS 26 or later and Xcode 26 or later.

```bash
swift build
swift test                                                      # runs in milliseconds
CONFIG=debug scripts/build-app.sh --open --demo --open-panel   # the app with sample data
```

Run against your own accounts with `"build/Token Anxiety.app/Contents/MacOS/TokenAnxiety" --print --debug`. Some services rate-limit bursts (Anthropic answers 429), so run it once rather than in a loop, and quit the installed app while you debug.

## How the code is laid out

- `Sources/TokenAnxietyCore`: everything that can be tested without a window.
  - `Providers/`: one actor per service, conforming to `UsageProvider` (`isInstalled()`, `fetch()`). Each has static `snapshot(...)` parsers that the tests feed with sample JSON.
  - `Models.swift` (`ProviderSnapshot`, `UsageWindow`, `ProviderError`), `Pace.swift`, `History.swift` (history and alert rules), `Formatting.swift`, `Demo.swift` (`--demo` data).
- `Sources/TokenAnxiety`: the app. `UsageStore` polls the providers, `StatusItemController` and `MenuBarRenderer` draw the menu bar item, `PanelController` hosts the SwiftUI panel, `Views/SettingsView` is the settings window.
- `scripts/build-app.sh` assembles and ad-hoc signs `build/Token Anxiety.app`.

## Adding a service

1. Add a case to `ProviderID` and an actor in `Sources/TokenAnxietyCore/Providers/` that conforms to `UsageProvider`.
2. Keep parsing in static functions that take the raw response, and test them with a sample response in `Tests/TokenAnxietyCoreTests` (with made-up values).
3. Read credentials the way the service's own app stores them, send them only to that service, and never log them.
4. Add the service to `UsageStore`, the `--print` doctor in `main.swift`, the demo data and the README table.

## Translating

The texts in the code are English and are the keys. A translation is a `Resources/<language>.lproj/Localizable.strings` file; `Resources/es.lproj` is the model to copy.

- Interpolated values become `%@` (text) or `%lld` (whole numbers), and a literal `%` is `%%`.
- Add the language code to `CFBundleLocalizations` in `Resources/Info.plist`.
- `scripts/check-strings.py Resources/<language>.lproj/Localizable.strings` lists the texts that are missing.
- Check it in the app with `"build/Token Anxiety.app/Contents/MacOS/TokenAnxiety" -AppleLanguages "(<language>)" --demo --open-panel`.

When you add or change a text in the code, update `Resources/es.lproj/Localizable.strings` too; `scripts/check-strings.py` fails while one is missing.

## Pull requests

- One topic per pull request, with tests for parsers and rules.
- `swift build` with no warnings, `swift test` and `scripts/check-strings.py` pass.
- Describe what you checked by hand (screenshots are welcome, with `--demo` data).
- Commit messages in English, in the imperative ("Show Cursor's on-demand spend").
