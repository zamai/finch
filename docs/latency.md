# Where the time goes

Measured on this machine (Darwin 25.6, Chrome running, config at `~/.finch.js`)
on 2026-10-20. Reproduce with `scripts/latency.sh <url>…`, which joins a send
timestamp against the wall clock Finch writes at the top of its handler, and
read the per-stage deltas off `~/.finch.log`.

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

## What is left, and whose cost it is

**The Meet PWA route is sometimes slow and has not been investigated.** Real
traffic shows `com.apple.iCal -> com.google.Chrome.app.kjgf… via=open
handoff=390ms` against `com.granola.app -> the same PWA, 21.8ms`. A Chrome PWA
shim is itself a relay process, so the likely story is the same one as above:
fast while the shim is resident, slow when it has to launch. Routing it down the
socket with `--app-id=` instead would plausibly fix it, and needs a test that
opens a tab.

`pre` — the gap between the click and Finch's handler — measured 65–110ms in
every sample, but each of those was triggered by `/usr/bin/open`, which spends
~40ms of that just starting up. For a click inside an already-running app the
remainder is LaunchServices resolving `com.finch.browser` and delivering the
Apple Event, and none of it is Finch's code. The log records the sending app as
`from=` on every line, so a slow real click can be attributed rather than
guessed at.
