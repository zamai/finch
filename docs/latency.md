# Where the time goes

Measured on this machine (Darwin 25.6, Chrome running, config at `~/.finch.js`)
on 2026-10-20. Every real click adds a line with per-stage deltas to
`~/.finch.log`, which is better data than synthetic `open` calls and opens no
windows.

## The answer

Routing is not the cost. Deciding which browser a URL goes to takes **5.4µs**
(`Finch --bench 20000 <url>`) — one five-thousandth of the smallest delay a
person can notice. Everything Finch does from receiving the Apple Event to
handing the URL to a browser is **1–3ms**.

The cost is the browser launch, and it splits in two:

| Route | What it does | Measured |
|---|---|---|
| no `args` | `NSWorkspace.open` → LaunchServices → Apple Event to the running browser | **14–22ms**, consistent |
| with `args`, as every other router does it | a second browser process starts, relays the URL to the running one, exits | **110ms warm, 170–600ms under load, 5.7s once** |
| with `args`, what Finch does now | writes the command line to the running browser's singleton socket | **0.1–0.3ms**; 3.4–7.5ms end to end |

## Why the args path used to cost a whole process

macOS discards launch arguments when the target app is already running, so
`--profile-directory` cannot reach a live Chrome. The documented way to get a
flag in front of a running single-instance browser is a fresh command line: a
new process starts, finds the profile already locked, hands the URL over a Unix
socket and exits. Chrome's framework is a couple of hundred megabytes, so that
process start is I/O bound — which is why the figure sits at ~110ms when those
pages are in cache and collapses to seconds when they are not. The 5.7s sample
came immediately after a `swift build` had evicted them.

Every router that supports Chrome profiles pays this. Finicky runs `open -n -a
<app> --args --profile-directory=…` ([issue
#364](https://github.com/johnste/finicky/issues/364)); grinch logs the same
strategy as `"launch_new_instance"` and says outright that "delivering a profile
requires launching Chrome with command-line arguments"; chowser's [PR
#55](https://github.com/bsreeram08/chowser/pull/55) narrows *when* a new
instance is forced but still needs one. The only speed work found in the wild
is a dotfiles [PR #70](https://github.com/technicalpickles/dotfiles/pull/70)
adding `--no-first-run --no-default-browser-check` to trim the throwaway
process's startup — it makes the relay cheaper, not unnecessary, and ships no
measurements.

## Skipping the relay entirely

The relay's only job is to write its command line to a socket. Finch writes to
that socket itself, so no second process starts at all. `Singleton.swift` has
the protocol; the short version is `START\0<cwd>\0<argv…>`, half-close, expect
`ACK`, and `argv[0]` must be the browser executable.

Verified rather than assumed: sending `--profile-directory=Profile 1` and
`--profile-directory=Profile 2` with different URLs put each URL in the matching
profile's `History` database. The reply came back `ACK` in 0.1–0.3ms.

It is an internal detail of a program Finch does not own, so it is written as a
pure optimisation — no socket, a refused connection, a `SHUTDOWN` reply or an
unrecognised one all fall back to spawning a real relay, and the trace line says
which and why. The fallback itself is now a direct `fork`/`exec` of the bundle
executable rather than a LaunchServices new-instance launch, which measured
**~70ms slower and spiked past 250ms** under load.

## Activation is a separate problem from delivery

Only a LaunchServices open raises a window. The socket delivers a URL to a
browser that stays exactly where it was, and so does a bare `fork`/`exec` — a
tab you cannot see has not really opened. This is easy to miss because the
no-args path never had the problem.

`NSRunningApplication.activate` is the obvious fix and the wrong one: deprecated
on macOS 14+, an AppKit call being made from a background queue, and a
`.prohibited` app is never frontmost enough for macOS to honour it on another
app's behalf. It measured 2.7ms and did nothing. Asking LaunchServices to open
the browser with no URLs is the supported path, and was checked not to add a tab
(37 open before, 37 after).

## What was ruled out, with evidence

- **The routing engine.** 5.4µs for a 7-rule config with two JS rewrite
  functions. The Slack permalink rewrite — the one route that re-enters
  JavaScriptCore — adds 2.8ms, and only on Slack links.
- **App Nap.** A URL opened after 150s of Finch sitting idle measured
  `pre=79.9ms total=18.8ms`: indistinguishable from back-to-back opens. Being a
  background `LSUIElement` app does not delay Apple Event delivery.
- **`NSEvent.modifierFlags`, opener resolution, route recording.** 0.0–0.2ms
  each, after the first call warms `NSRunningApplication`.
- **LaunchServices app lookup.** Was ~1ms per route; now cached per bundle id
  and cleared on config reload, so it is 0.0ms.
- **Reading Chrome's last-used profile to skip the relay.** This would have made
  the args path as fast as the plain one whenever the wanted profile was already
  in front. It does not work: `profile.last_used` in Chrome's `Local State` did
  not change after a Profile 2 window was opened and focused, because Chrome
  only flushes that file periodically. Acting on it would route work links into
  the personal profile some of the time. Abandoned, and recorded here so it is
  not tried again.
- **Dropping `--profile-directory` and letting work links land in the last-used
  window.** Fast and wrong: profile switching is the reason this fork exists.
- **Targeting a profile's window by Apple Event instead.** Chrome's AppleScript
  dictionary exposes window `id`, `title` and `mode`, but nothing that says
  which profile a window belongs to, so there is no way to pick the right one.

## The Meet PWA route: investigated, left alone

Real traffic showed `com.apple.iCal -> com.google.Chrome.app.kjgf… via=open
handoff=390ms`, against 21.8ms for the same PWA from `com.granola.app`. The
cause is the same shape as the profile relay: a Chrome PWA is a real app bundle
whose executable is `app_mode_loader`, so LaunchServices has to launch a process
whenever no Meet window is open. While one is open the shim is resident and the
open is just an Apple Event — hence 21.8ms.

The obvious fix was to send the PWA's flags down the singleton socket like any
other profile route. It does not work, and both attempts are worth recording
because each fails for a different reason.

| Sent over the socket | Result |
|---|---|
| `--profile-directory=Profile 1 --app-id=kjgf… <url>` | `ACK` in 0.2ms, opens the real PWA, **ignores the URL** — the window loaded `meet.google.com/home?lfhs=2`, the app's own start URL, not the URL passed. A meeting link would land on Meet's home page. |
| `--profile-directory=Profile 1 --app=<url>` | `ACK` in 0.2–0.4ms, honours both URL and profile, but **is not the installed web app**. Checked by watching for the shim: `--app-id` makes Chrome launch `app_mode_loader --launched-by-chrome-process-id=…`, `--app=` never does. So the window has no Google Meet identity in the Dock or ⌘-Tab. |

The reason no command line can do this: the shim forwards an opened URL to
Chrome over the app-shim IPC channel, not on a command line, so there is no flag
that means "navigate app X to URL Y".

Left as it is, deliberately. The 390ms only happens on the first Meet link while
no Meet window is open, it is an order of magnitude smaller than the worst case
the socket removed, and both alternatives trade away the PWA to buy it.

## A profile link sometimes opens a new window: Chrome's choice, not Finch's

Seen 2026-10-26: a Telegram link routed to Profile 1 `via=socket` landed in the
right profile, but in a new window beside an existing Profile 1 window. The
Google Meet PWA, also Profile 1, was running.

Chrome has two paths for an incoming URL, and they choose the window
differently (`chromium/chromium`, main, read 2026-10-26):

| Path | Who uses it | Window chosen |
|---|---|---|
| Apple Event (`app_controller_mac.mm`, `OpenStartupTabsInBrowserWithProfile`) | a plain `NSWorkspace.open`: Finch's no-args path, and Chrome as default browser | `FindTabbedBrowser()` — commented *"not in PWA/app windows which cannot accept new tabs"* |
| Command line (`startup_browser_creator_impl.cc`, `GetExistingBrowserForOpenBehavior`) | anything carrying `--profile-directory`: the singleton socket, the relay, every other router | the profile's **last active window of any type**; if that is not a normal tabbed window, `OpenTabsInBrowser` creates a new one |

So whenever the target profile's most recently focused window is the Meet PWA
(or a popup or other app window), a profile link opens a new window. The
socket did not cause this, and the relay it replaced behaves the same way.
There is no switch to change it: `startup_browser_creator_impl.cc` reads only
`--new-window`, `--same-tab`, `--open-in-background` and a few unrelated ones.
The Apple Event path cannot name a profile; it uses Chrome's last profile,
which `windowDidBecomeMain` sets from any browser window, apps included.

What a fix would need: make a tabbed window of the target profile Chrome's
last active one before delivering. The profile can be read from the window's
accessibility title (`… - Google Chrome - Alex (cast.ai)`; Chrome appends the
profile name when there is more than one), but that needs Accessibility
permission. With Finch's ad-hoc signature, macOS keys the permission to the
binary's hash, so it is lost on every `make install`. That needs a stable
local signing identity first.

## What is left, and whose cost it is

`pre` — the gap between the click and Finch's handler — measured 65–110ms in
every sample, but each of those was triggered by `/usr/bin/open`, which spends
~40ms of that just starting up. For a click inside an already-running app the
remainder is LaunchServices resolving `com.finch.browser` and delivering the
Apple Event, and none of it is Finch's code. The log records the sending app as
`from=` on every line, so a slow real click can be attributed rather than
guessed at.
