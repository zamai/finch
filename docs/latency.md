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
| no `args` | `NSWorkspace.open` → LaunchServices → Apple Event to the running browser | **15–22ms**, consistent |
| with `args` | a second browser process starts, relays the URL to the running one, exits | **110ms warm, 170–600ms under load, 5.7s once** |

So a link to `example.com` (the bare `chrome` browser) is as fast as clicking a
link inside Chrome already is. A link to `github.com` (the `chromeWork` browser,
which carries `--profile-directory=Profile 1`) costs an extra Chrome process
start, and *that* is the delay that reads as "sometimes it takes a second".

## Why the args path costs a whole process

macOS discards launch arguments when the target app is already running, so
`--profile-directory` cannot reach a live Chrome. The only way to get a flag in
front of a running single-instance browser is a fresh command line: a new
process starts, finds the profile already locked, hands the URL over its
singleton socket and exits. Chrome's framework is a couple of hundred megabytes,
so that process start is I/O bound — which is exactly why the figure is stable
at ~110ms when those pages are in cache and collapses to seconds when they are
not. The 5.7s sample came immediately after a `swift build`, which had evicted
them.

Finch now spawns that relay itself rather than asking LaunchServices to create a
new application instance. Same mechanism as `open -n -a <app> --args …`, minus
LaunchServices' launch machinery, which measured **~70ms slower and spiked past
250ms** under load. The spawn happens on a background queue, so the ~1ms of
fork/exec is not even on the Apple Event handler's path.

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

## What is left, and whose cost it is

`pre` — the gap between the click and Finch's handler — measured 65–110ms in
every sample, but each of those was triggered by `/usr/bin/open`, which spends
~40ms of that just starting up. For a click inside an already-running app the
remainder is LaunchServices resolving `com.finch.browser` and delivering the
Apple Event, and none of it is Finch's code. The log records the sending app as
`from=` on every line, so a slow real click can be attributed rather than
guessed at.
