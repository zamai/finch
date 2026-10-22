# Finch — agent orientation

Finch is a macOS browser router: it registers as the default browser and sends
each URL to a browser, Chrome profile or app chosen by `~/.finch.js`. Swift plus
JavaScriptCore. The goal is speed and reliability for one person's config;
anything else is a candidate for deletion. `make loc` prints the size (669 code
lines at the last count).

This is a solo fork (`zamai/finch`, the only remote). Commit straight to
`main`: no branches, no PRs, no releases. It is not the upstream
`expelledboy/finch`, which is not tracked.

**This file is an index.** Follow the pointer and read the source rather than
copying facts in. When you add a document, a file or something outside the
repo, add a row. Only point at committed files: `.claude/` is gitignored.

## Read before you act

| Before you… | Read | It already settles |
|---|---|---|
| chase a slow link open, or change how a URL reaches the browser | `docs/latency.md` | the measured cost of each stage (delivery to the browser, never routing), how `--profile-directory` reaches a running Chrome down its singleton socket, how the window gets raised, and six fixes already tested and ruled out — including Chrome's `last_used`, `--app-id` and `--app=` for the Meet PWA |
| add config syntax, or ask "why JavaScriptCore", "why marker objects" | `docs/architecture.md` | the goal, why the config surface is deliberately small and enforced, the never-lose-a-link rules, and the macOS behaviour `Info.plist` encodes |
| change config syntax or what it accepts | `~/.finch.js`, then README.md § Configuration | the live config is the spec: syntax it does not use was removed. Check a change against it with `make test URL=…`, or try another file with `FINCH_CONFIG=<path>` |
| touch the bundle, URL schemes, or default-browser candidacy | `Info.plist`, then `docs/architecture.md` § Platform behaviour | which schemes Finch claims and why not `public.html`; `LSUIElement`; why `NSUserActivityTypeBrowsingWeb` must stay |
| build, install or measure | `Makefile` | `install` (the only way to run it), `test URL=…`, `trace`, `loc` |

## Source map

| File | Responsibility |
|---|---|
| `Sources/Finch/main.swift` | Entry point; the activation policy that keeps Finch out of the Dock |
| `Sources/Finch/AppDelegate.swift` | Apple Event (`GURL`) handling; delivering the URL (plain open, launch with args, singleton socket, relay fallback) and raising the window; the Safari fallback; the menu bar; `--test` and `--bench` |
| `Sources/Finch/Engine.swift` | The hot path: config compiled to native matchers, rewrites, first match wins. Rejects anything it does not understand |
| `Sources/Finch/Loader.swift` | Reads `~/.finch.js` (or `FINCH_CONFIG`) into a JavaScriptCore context |
| `Sources/Finch/Helpers.swift` | `JS_PRELUDE`: a `URL` polyfill (JavaScriptCore has no DOM) and `domain()`, which returns data so the engine can compile it |
| `Sources/Finch/Recents.swift` | The last 10 routes with timings, in memory, for the menu bar |
| `Sources/Finch/Trace.swift` | Per-route latency trace and error reports, written off the main thread to `~/.finch.log` and `os_log` (`make trace`) |
| `Sources/Finch/Singleton.swift` | Chromium's process-singleton socket protocol: how a profile flag reaches a running Chrome without starting a second one. The biggest latency win; read `docs/latency.md` first |

## Verifying a change without opening windows

The author works on this machine, and every real open puts a window in front
of them. Prefer checks that open nothing:

- Routing: run `.build/release/Finch --test <url>` over a set of URLs before
  and after, and diff the output.
- Speed: `.build/release/Finch --bench 20000 <url>`.
- Delivery: `make install` (no window), then read `~/.finch.log` after the
  author's own clicks. Real clicks carry the sending app and are better data.

Ask before anything that opens a URL.

## Not in this repository

| What | Where | Why it matters |
|---|---|---|
| The live routing rules | `~/.finch.js`, a symlink to `~/Code/mac-setup/finch.js` | The spec for what the config must support. Not an example: edit it only when asked |
| The installed application | `/Applications/Finch.app` | What LaunchServices sends links to. `make install` replaces it |
| The route log | `~/.finch.log` (rotated at 1MB to `.finch.log.1`) | Timings, sender and path per link, plus config loads and errors. No URLs |

## Gotchas with no other home

- **Two copies of the app fight over the bundle id.** LaunchServices sends
  `com.finch.browser` links to whichever bundle registered last. That is why
  there is no `make run`. If a stray copy got registered, undo with
  `lsregister -u <path>/Finch.app` then `lsregister -f /Applications/Finch.app`.
  The binary is
  `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister`.
- **The sender must come from the Apple Event's sender pid.**
  `NSWorkspace.frontmostApplication` reports Finch itself, because handling the
  event makes Finch frontmost. See `openerBundleId` in `AppDelegate.swift`.
- **A stale URL-scheme binding survives `lsregister -kill -r`.** `lsd` keeps
  serving its in-memory map; kill it too. See `docs/architecture.md` § Platform
  behaviour.
- **The menu bar icon can be placed off-screen.** macOS persists its slot in
  `NSStatusItem Preferred Position Item-0` under the `com.finch.browser`
  defaults domain. Quit Finch, `defaults delete` that key, relaunch.
  Accessibility has reported off-screen coordinates for a visible icon, so do
  not trust it as a check.
