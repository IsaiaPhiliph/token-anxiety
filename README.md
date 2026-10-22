# Token Anxiety

<img src="Resources/AppIcon.png" width="112" align="right" alt="Token Anxiety icon">

A macOS menu bar app that shows how much of your AI plans you have used: the five-hour and weekly windows of each service, always in sight. Click it for a Liquid Glass panel with the details: when each window resets, how fast you are spending, per-model limits and a chart of the last 7 days.

It speaks English and Spanish, following your Mac's language.

<p align="center">
  <img src="docs/panel-dark.png" width="340" alt="The Token Anxiety menu bar item with its panel open below, showing sample data">
  <br>
  <sub>With the sample data from <code>--demo</code>.</sub>
</p>

## What it tracks

Services are found on their own, through the session each app already keeps on your Mac. Any of them can be hidden, or kept out of the menu bar, in Settings.

| Service | Where the figures come from | What it shows |
| --- | --- | --- |
| **Claude** (Pro, Max) | Claude Code's session in the Keychain, against the endpoint its `/usage` command reads | 5-hour session, week, Opus and Sonnet weeks, extra usage |
| **ChatGPT / Codex** | Codex itself (`codex app-server`, which manages its own session) | 5 hours and week (the Free plan has a monthly limit), credits, streak and tokens per day |
| **Antigravity** | Its local language server, only while the app is open | Each model's quota |
| **Cursor** | The Cursor app's session, against its usage dashboard | This month's usage (no 5-hour or weekly window, so by default it only shows in the panel) |

In the menu bar each service shows its icon and two figures: `34% · 61%` means 34% of the five-hour window and 61% of the week. Settings has two more styles (double bars, figure + bar), and figures turn orange and red past the alert thresholds.

### Extras

- **Alerts**: a notification at 80% and 95% (both thresholds can be changed), another when a window runs out, and another when the quota comes back.
- **Weekly pace**: compares what you have spent with an even spend and tells you whether, at this pace, you will hit 100% before the week resets.
- **History**: keeps the figures on your Mac and draws the last 7 days.
- **Open at login**: turned on by itself the first time the app is opened from Applications.

## Install

Token Anxiety needs macOS 26 or later. There are no prebuilt downloads yet: build it with Xcode 26 or later (or its command line tools).

```bash
git clone https://github.com/IsaiaPhiliph/token-anxiety.git
cd token-anxiety
scripts/build-app.sh --install
```

This builds a release version, signs it for your Mac (ad hoc), copies it to `/Applications` and opens it.

## Privacy

- Sessions are read on your Mac, and each token is only sent to its own service (Anthropic, OpenAI, Cursor). Antigravity is asked on `127.0.0.1`.
- Nothing is collected or sent anywhere else: there are no analytics.
- Claude Code's session lasts 8 hours, and only the `claude` command renews it. When it has expired, Token Anxiety renews it the way Claude Code does and saves it back in the same Keychain item, leaving every other field alone, so Claude Code keeps working. This can be turned off in Settings.
- The history and the latest figures are kept in `~/Library/Application Support/TokenAnxiety/state.json`.

## Troubleshooting

- **Claude: "Claude Code can no longer renew its session"**: Claude Code's saved session is no longer valid. Run `claude` in a terminal and `/login`; the app keeps it alive from then on.
- **Antigravity: "Open Antigravity"**: it only gives its quota while the app is open.
- **No alerts show up**: Settings › Alerts shows a line when macOS blocks them or keeps them off screen, with a button that opens the right pane of System Settings. "Send a test alert" shows what they look like.
- None of these services has a public usage API. If one changes its format, that service shows a warning until Token Anxiety catches up, without affecting the others. Please [open an issue](https://github.com/IsaiaPhiliph/token-anxiety/issues) if you see one.

## Development

```bash
CONFIG=debug scripts/build-app.sh --open --demo --open-panel   # sample data, panel open
swift test                                                      # parsers, pace and alert rules
"build/Token Anxiety.app/Contents/MacOS/TokenAnxiety" --print --debug   # diagnostics in the terminal
```

`--print` asks every service once and prints the figures (never tokens or emails); `--debug` adds each step. See [CONTRIBUTING.md](CONTRIBUTING.md) for how the code is laid out, how to add a service and how to translate the app.

## Disclaimer

Token Anxiety is an independent project. It is not affiliated with or endorsed by Anthropic, OpenAI, Google or Anysphere (Cursor). It reads undocumented endpoints that may change at any time.

## License

[MIT](LICENSE)
