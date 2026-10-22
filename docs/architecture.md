# Architecture and design decisions

Why Finch is built the way it is. A change should be argued against this.

## The goal

One job: get a link into the right browser profile or app as fast as the
browser itself would open it, and never lose a link. Speed and reliability
first; expressiveness only as far as one real config needs it.

Routing has a budget of 10µs and measures ~5µs (`Finch --bench`). The cost a
user can feel is delivering the URL to the browser, and
[latency.md](latency.md) is the record of what that costs and why.

## Key decisions

**JavaScriptCore for the config.** Apple's JavaScript engine ships with macOS
and costs nothing to link, so there is no bundler, transpiler or embedded
interpreter. Rewrites that rebuild a URL (Slack permalinks into `slack://`
deep links) are ordinary functions rather than a mini-language. The price is
that Finch is macOS-only.

**Compile the config, don't call it.** `domain()` returns a plain data object,
not a function. `Engine.swift` turns it, hostname strings and regex literals
into native Swift matchers once, at load. Matching never enters JavaScript; the
bridge is crossed only for a rewrite whose matcher has already hit. A call
through the bridge costs more than the match it would replace, and this is the
decision the speed rests on.

**A small surface, enforced.** The config accepts what the live config uses
and rejects everything else at load, naming the rule. The upstream project
also had `from()`, `running()`, `strip()`, function predicates and dynamic
targets; they were removed rather than left unused, because each was code on
the hot path and a way for a typo to be skipped silently.

**Never lose a link.** A rejected reload keeps the previous engine. No config
at launch sends links to Safari. A rewrite that returns a non-URL falls back to
the URL as received. Every failure is a line in `~/.finch.log`, because an
`LSUIElement` app has no other place to say anything.

## Platform behaviour this depends on

Facts about macOS that the bundle configuration encodes, each learned by being
bitten. Not an exhaustive catalogue — add to it when the next one costs you a
day. Changing `Info.plist` without knowing these will break things quietly.

**Default-browser candidacy comes from `CFBundleURLTypes` plus
`NSUserActivityTypeBrowsingWeb`, not from `CFBundleDocumentTypes`.** Finch
claims the `http`, `https` and `mailto` URL schemes and nothing else. It used to
also claim the HTML *document type*, which made `open foo.html` fail with
"Finch cannot open files in the 'HTML Document' format" — Finch is a router, it
has no renderer. Dropping that claim in v0.1.1 fixed the dialog and did not
affect default-browser candidacy, because the two come from different plist
keys. Opening local HTML files is a separate binding the user owns, via Finder's
"Open with → Change All" or `duti -s <bundle id> public.html all`.

**A stale handler preference survives a Launch Services database rebuild.**
Launch Services is the macOS subsystem that decides which app opens a given URL
scheme or file type, the latter identified by a Uniform Type Identifier (UTI)
such as `public.html`. `lsregister -kill -r` rebuilds the on-disk database but leaves an
in-memory handler map inside `lsd`, the Launch Services daemon, which continues
to serve the old answer. `lsd` has to be killed as well before the rebuild takes
effect. Symptom: a URL scheme or file type keeps opening the wrong app no matter
how many times you re-register.
