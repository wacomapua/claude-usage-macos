# Claude Usage

A macOS widget that tracks Claude Code usage across multiple accounts — session (5-hour)
and weekly limits, per-model weekly limits, and extra-usage spend.

Built for a two-account setup (`~/.claude-personal` and `~/.claude-work`), but it
discovers every account automatically, so any number works.

## Where the numbers come from

Claude Code caches the figures `/usage` shows in `<configDir>/.claude.json`, under
`cachedUsageUtilization`:

```jsonc
{
  "oauthAccount": { "emailAddress": "...", "organizationType": "claude_max", ... },
  "cachedUsageUtilization": {
    "fetchedAtMs": 1785312671244,
    "utilization": {
      "five_hour": { "utilization": 17, "resets_at": "..." },
      "seven_day": { "utilization": 15, "resets_at": "..." },
      "limits":    [ { "kind": "weekly_scoped", "percent": 3, "scope": { "model": { "display_name": "Opus" } } } ],
      "spend":     { "used": { "amount_minor": 4655, "currency": "AUD", "exponent": 2 }, "enabled": true }
    }
  }
}
```

Accounts are separated by `CLAUDE_CONFIG_DIR`, so each account is simply a different
directory. The app reads every `~/.claude` and `~/.claude-*` directory that contains a
`.claude.json`.

### This is a cache, and the widget says so

The file is only rewritten while Claude Code is running under that account. If an account
sits idle its numbers stop updating, so every layout carries an `as of …` marker that
turns orange past 45 minutes.

Two related honesty details:

- When a window's `resets_at` has already passed, the cached percentage is history. The
  bar greys out and reads **reset** rather than pretending the old figure still stands.
- An expired window is excluded from the headline percentage on the small widget.

Live refresh is possible — Claude Code itself calls
`GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` and
`anthropic-beta: oauth-2025-04-20` — but it needs the per-account OAuth token, and this
build deliberately does not touch credentials. `ClaudeConfigReader` is the only source of
data, so adding a live fetcher later means adding a second source behind the same model.

## Architecture

macOS forces widget extensions to be sandboxed, so the widget cannot read `~/.claude-*`
itself. The split:

```
ClaudeUsage.app          non-sandboxed  reads ~/.claude-*  ─┐
                                                            ├─ usage-snapshot.json
ClaudeUsageWidget.appex  sandboxed      reads the snapshot ─┘
```

`SnapshotStore` supports two transports and tries them in order:

1. **App Group container** — the textbook approach, used automatically if the entitlement
   is present. It needs a provisioning profile for a registered App Group ID.
2. **The widget's own sandbox container** — a sandboxed extension may always read its own
   Application Support directory, and the non-sandboxed host app may write into it. No
   entitlements, no profile, no paid developer account. **This is what the build uses.**

Because of transport 2, the project signs ad-hoc and builds with no developer account.

> One wrinkle worth knowing: macOS recreates an extension's container the first time it
> registers the widget, which wipes whatever is in it. `UsageMonitor` therefore rewrites
> the snapshot whenever it goes missing, not only when a config file changes.

## Building

```bash
xcodegen generate
xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
           -configuration Release -derivedDataPath build build
cp -R build/Build/Products/Release/ClaudeUsage.app /Applications/
open -a /Applications/ClaudeUsage.app
```

Then add the widget: right-click the desktop → **Edit Widgets** → search "Claude Usage".
The same widget also appears in Notification Centre (swipe in from the right edge).

Keep the app running — or tick **Launch at login** in its window — so the snapshot the
widget reads stays current.

## Layouts

| Family | Shows |
| --- | --- |
| Small | Headline % per account plus hairline session/weekly bars |
| Medium | One column per account: session + weekly bars, reset countdowns, staleness |
| Large | Everything, including per-model weekly limits and extra-usage spend |

## Previewing without installing

`Tools/render.sh` renders every layout to PNGs at real widget dimensions, in light and
dark, using your actual snapshot if one exists:

```bash
./Tools/render.sh          # → build/previews/*.png
```

This works because the layouts live in `Shared/UsageWidgetViews.swift` rather than in the
widget target, and each takes its "now" as a parameter — WidgetKit renders timeline
entries ahead of time, so reading the clock at draw time would freeze every countdown.

## Layout

```
Shared/     Models, config reader, snapshot transport, widget layouts (in both targets)
App/        Non-sandboxed host app: file watching, snapshot publishing, settings window
Widget/     WidgetKit extension: timeline provider + family switch
Tools/      PNG preview renderer
```
