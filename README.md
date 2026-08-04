# Claude Usage

A macOS widget that tracks Claude Code usage across multiple accounts — session (5-hour)
and weekly limits, per-model weekly limits, and extra-usage spend.

Built for a two-account setup (`~/.claude-personal` and `~/.claude-work`), but it
discovers every account automatically, so any number works.

## Account discovery

Works with one account or several, and finds them without configuration. There are
**two different on-disk layouts**, and they are not the same shape:

| Install | Config file | Data directory |
| --- | --- | --- |
| Default (no `CLAUDE_CONFIG_DIR`) | `~/.claude.json` | `~/.claude/` |
| `CLAUDE_CONFIG_DIR=~/.claude-work` | `~/.claude-work/.claude.json` | `~/.claude-work/` |

The default install keeps its config **beside** the data directory, not inside it.
An earlier version only looked for `<dir>/.claude.json`, so it silently found nothing
on a plain single-account setup — the most common case of all.

An account is only listed if it shows **evidence of use**: a `cachedUsageUtilization`
block, or an `oauthAccount` plus a non-empty `projects/` directory. That keeps a
leftover `~/.claude.json` — the kind left behind after switching to per-account
directories — from showing up as a phantom third account.

## Live usage (optional)

Off by default. When enabled, the app skips the cache and asks the API directly, so
the numbers stop depending on when Claude Code last ran.

Claude Code stores each account's OAuth token in the login Keychain. The service name
is `Claude Code-credentials`, suffixed with the first 8 hex characters of the SHA-256
of `CLAUDE_CONFIG_DIR` when that's set — which is exactly what keeps several accounts'
tokens apart on one machine:

```
~/.claude-personal  →  Claude Code-credentials-c017d112
~/.claude-work      →  Claude Code-credentials-cb899d8d
default install     →  Claude Code-credentials
```

With that token, `GET https://api.anthropic.com/api/oauth/usage` (plus
`anthropic-beta: oauth-2025-04-20`) returns the same payload the cache is a verbatim
copy of — so the identical parser serves both paths.

**It is strictly read-only.** The app never writes to the Keychain and never refreshes
an expired token. Refresh tokens rotate: spending one here could invalidate the copy
Claude Code holds and sign you out of the CLI. An expired token falls back to the
cached numbers, and Claude Code refreshes it itself next time it runs.

macOS prompts once for Keychain access, since the item belongs to another app.

## Two data sources

| Source | Gives | Freshness |
| --- | --- | --- |
| `<configDir>/.claude.json` → `cachedUsageUtilization` | Limit percentages, reset times, plan, extra-usage spend | Only while Claude Code runs |
| `<configDir>/projects/**/*.jsonl` (transcripts) | Token counts, API-equivalent value, hourly burn history, model mix, turn count, top project | Every assistant turn |

The second source is the interesting one. The usage cache is a single instantaneous
reading; the transcripts record **every** assistant turn with its timestamp, model,
and full `usage` block — so the shape of a working day is recoverable, and so is
what that day would have cost.

### Value is API-equivalent, not a bill

Token value is computed from Claude API list rates and is **not** charged on a Max
or Team subscription. It answers "what would this have cost on the API", which is
the only honest way to put a number on subscription usage.

Rates per million tokens, applied per model family from the transcript's `model` field:

| | Input | Output |
| --- | ---: | ---: |
| Fable / Mythos | $10 | $50 |
| Opus | $5 | $25 |
| Sonnet | $3 ($2 intro through 2026-08-31) | $15 ($10 intro) |
| Haiku | $1 | $5 |

Cache traffic is priced off the input rate: reads ×0.1, 5-minute writes ×1.25,
1-hour writes ×2. The transcript records the 5-minute and 1-hour cache splits
separately, so those two write rates are applied correctly rather than averaged.

### Scanning cost

A cold scan of ~260 recent transcript files (~200MB) takes well under a second.
Files are append-only, so each is read once in full and thereafter only from the
byte offset where the last read stopped — warm rescans touch almost nothing. The
scan runs off the main thread on a 60-second cadence, separate from the 15-second
config-file poll.

## Where the limit percentages come from

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

## Code signing

The project signs with the **"Apple Development" certificate already in your login
Keychain** — not ad-hoc, and with no provisioning profile (nothing here requests a
restricted entitlement since the App Group was dropped).

That choice is about the Keychain, not distribution. "Always Allow" on a Keychain
prompt stores an ACL against the app's *designated requirement*. Ad-hoc signing makes
that requirement a bare `cdhash` — the hash of one exact binary — so every rebuild
looks like a different app and macOS asks again. A real certificate gives:

```
identifier "com.wacomapua.claudeusage" and anchor apple generic
  and certificate leaf[subject.CN] = "Apple Development: …"
```

which survives rebuilds, so the grant sticks.

Set `CODE_SIGN_IDENTITY` in `project.yml` to your own certificate name
(`security find-identity -v -p codesigning` lists them). Leave `DEVELOPMENT_TEAM`
empty — setting it makes Xcode insist on a "Mac Development" certificate, which
requires Xcode to be signed in to the developer account.

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

A tachometer shows its **whole range**, not just the needle. The unfilled arc carries
the full cool-to-hot ramp at low opacity, with a redline band over the last 15% — so
the face reads as an instrument even at 6%, instead of being a mostly-empty grey ring
with a small coloured stub.

Everything else — labels, countdowns, separators — is deliberately quiet so the
reading is the only thing competing for attention. No cards inside the widgets: a card
drawn on a widget is a box inside a box, and its border ends up fighting the dial.
Accounts are separated by space and a hairline instead.

### The arc is a lit channel, not a stroke

The reading is drawn twice: a wide soft flood the full width of the channel, and a
narrow filament at ~34% of that width burning at full strength down the middle, with
two shadow passes at different radii. The result reads as light travelling through a
tube rather than as paint on a ring — and it's what lets the same component look calm
at 17% and genuinely alarming at 94%.

### Bloom

A soft radial wash tinted by each dial's own reading sits behind the whole widget, so
the surface takes on the mood of the numbers — cool green when idle, deep red when
you're about to run out.

It has to live at the **widget root**, not behind each account block. A radial
gradient painted behind a block is clipped to that block's rectangle, and wherever it
hasn't faded to zero by the edge you get a visible hard-edged box. At the root the
only boundary is the widget's own rounded outline.

Three palettes, kept deliberately separate so two different readings can't be confused:

- **Severity** — the cool-to-hot ramp on the dial, meters, and burn bars
- **Model families** — violet Opus, magenta Fable, blue Sonnet, teal Haiku
- **Structure** — explicit greys for labels and metadata

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
| Small | A dial per account over its session token count and value |
| Medium | Dial, session tokens + value, burn sparkline, weekly line — per account |
| Large | Adds the weekly meter, model mix with legend, turn count, weekly value, top project |

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

## Known issues

**The app stops updating the widget when its window is closed.** `UsageMonitor` is
created by the window scene's `@StateObject`, which SwiftUI instantiates lazily when a
window's body is first evaluated — so launching with no window (which macOS does when
it restores that state) means nothing polls, scans, or publishes. Open the window and
it resumes. The fix is to own the monitor at app level instead; a first attempt at that
is on `feat/consent-gate` and is not yet working.

**`feat/consent-gate` is unfinished.** It adds a first-run screen that states what gets
read, lets you choose which accounts to include, and can redact email addresses from
the app, the widget and the snapshot file. The gating logic verifies correct under
instrumentation, but snapshot publishing regresses on that branch. Don't merge it until
that's resolved.
