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

## Design

One reading per account, large, on an open face. The dial is a 270° sweep with the gap at
the bottom; the arc is thick enough to carry a gradient, and everything else — labels,
countdowns, separators — is deliberately quiet so the number is the only thing competing
for attention. No cards inside the widgets: a card drawn on a widget is a box inside a
box, and its border ends up fighting the dial. Accounts are separated by space and a
hairline instead.

The arc is a real `Shape` rather than a rotated, trimmed `Circle`, so its angular gradient
lines up with actual screen angles instead of drifting with the rotation.

### Colour

Hue carries severity; the gradient along each arc carries depth. `Dial.arcEnds` returns a
lighter shade where the arc starts and a saturated one at its tip, so the sweep always
looks designed rather than like a temperature readout.

The scale is defined twice. Luminous accents look superb on graphite and wash out to
nothing on white, so the light scheme gets its own deeper ramp rather than the dark one at
reduced opacity:

| | calm | warm | hot | critical |
| --- | --- | --- | --- | --- |
| Dark | `#3BE8B0` | `#FFC66B` | `#FF8A6B` | `#FF5C7A` |
| Light | `#08A37B` | `#C98A12` | `#D4541F` | `#C81E45` |

Text greys are explicit (`Dial.label`, `Dial.meta`) rather than the system `.secondary` /
`.tertiary` hierarchy, which is far too faint on a light background at the 8–9pt sizes
this widget is mostly made of.

### The pace reference

A speedometer measures rate, and so does this. A quota bar can tell you how much you've
spent but not whether that's *fast*. Because we know both the percentage and when the
window closes, we know how far through the window you are — and therefore where an even
burn would have put you by now. That point is drawn as a thin arc inset inside the main
band:

- Reference arc **longer** than the reading → `under pace`, cruising
- Reference arc **swallowed** by it → `over pace`, you'll run out early

Two earlier attempts are worth recording as dead ends. Drawn as a tick on the ring it read
as a broken needle. Drawn at full band width it read as the *value* — the eye takes the
longest arc for the reading, which at low usage says the opposite of the truth. Thin and
inset, it stays a reference.

This is the one thing here a plain progress bar cannot express, and it comes free from
data already on disk (`Pace` in `Shared/UsageDesign.swift`).

## Layouts

| Family | Shows |
| --- | --- |
| Small | A dial per account with the weekly figure beneath |
| Medium | Two large dials side by side, split by a hairline |
| Large | Everything, including per-model weekly limits and extra-usage spend |

## Previewing without installing

`Tools/render.sh` renders every layout to PNGs at real widget dimensions, in light and
dark, using your actual snapshot if one exists:

```bash
./Tools/render.sh                                    # → build/previews/*.png
build/previews/render-previews build/previews --stress   # → stress-*.png
```

`--stress` renders synthetic data instead: a dial at 94% burning over pace, a weekly
limit at 68%, and a window that has already rolled over. Real usage tends to sit at the
cool end of the scale, so without this the hot half of the design never gets reviewed.

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
