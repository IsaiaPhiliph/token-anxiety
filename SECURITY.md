# Security policy

Token Anxiety reads the sign-in sessions of other apps (Claude Code, Codex, Cursor, Antigravity) and, for Claude Code, renews and saves its session in the Keychain. Bugs in that code can leak or break those sessions, so please report them privately.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/IsaiaPhiliph/token-anxiety/security/advisories/new) for this repository. Please do not open a public issue.

Include what you found, how to reproduce it and what an attacker could do with it. Never include real tokens or cookies: describe them instead.

You should get an answer within a week. Fixes are released as soon as they are ready, and you are credited unless you prefer otherwise.

## What counts

- A token, cookie or email written to a log, a file, the terminal or a crash report.
- A token sent anywhere other than its own service.
- A Keychain write that can lose or corrupt Claude Code's saved session.
- Anything that lets another process read data through Token Anxiety that it could not read before.

## Supported versions

Only the latest version on `main` gets security fixes.
