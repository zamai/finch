# Finch

A macOS browser router that is fast at one thing: sending each link to the
right Chrome profile, or the right app, in milliseconds.

Finch registers as the default browser. Every `http`, `https` and `mailto`
link goes through the rules in `~/.finch.js`, then on to a browser or app.
Routing takes about 5µs. Opening a link in a Chrome profile that is already
running takes 3–40ms end to end, against the ~110ms to several seconds that
other routers spend starting a second Chrome process to carry the
`--profile-directory` flag. [docs/latency.md](docs/latency.md) has the
measurements and how it is done.

A personal fork of [`expelledboy/finch`](https://github.com/expelledboy/finch),
trimmed to what one config uses. MIT, see [LICENSE](LICENSE).

## Install

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/zamai/finch && cd finch
make install    # build, copy to /Applications, register, launch
```

Then **System Settings → Desktop & Dock → Default web browser → Finch**. Finch
has no window and no Dock icon, only 🐦 in the menu bar.

## Configuration

`~/.finch.js` is JavaScript evaluated by JavaScriptCore:

```js
module.exports = {
  default: "chrome",                         // when no rule matches

  browsers: {                                // name → bundle id or { id, args }
    chrome: "com.google.Chrome",
    work:   { id: "com.google.Chrome", args: ["--profile-directory=Profile 1"] },
    slack:  "com.tinyspeck.slackmacgap",
  },

  rewrite: [                                 // every matching rewrite applies, in order
    { match: /^https:\/\/discord\.com\//, url: (href) => href.replace(/^https/, "discord") },
  ],

  rules: [                                   // first match wins, on the rewritten URL
    { match: /^slack:/, open: "slack" },
    { match: domain("github.com", "atlassian.net"), open: "work" },
  ],
};
```

| `match` | Matches |
|---|---|
| `"example.com"` | that host or any subdomain |
| `domain("a.com", "b.com")` | any of those hosts or their subdomains |
| `/regex/` | the full URL, case-insensitive |
| `[…]` | any of the above |

`open` and `default` take a name from `browsers` or a bare bundle id. A
rewrite's `url` is a function from the URL string to a new one, and `URL` is
available inside it for parsing.

Anything else is rejected when the config loads, with the offending rule named
in `~/.finch.log`, so a typo cannot quietly send links to the wrong profile. If
a reload is rejected the previous config keeps running. If no config has
loaded since launch, links go to Safari rather than nowhere.

Reload after editing: menu bar → **Reload Config**, or
`kill -HUP $(pgrep -f Finch.app/Contents/MacOS/Finch)`.

## Seeing what happened

- **Menu bar:** the last 10 links, with where each went and how long it took.
  Click one to copy its URL.
- **`~/.finch.log`:** one line per link with per-stage timings, the sending
  app and the path taken (`via=socket`, `open`, `launch`, `relay`), plus
  config loads and errors. URLs are not written. `make trace` streams the
  same lines live.

## Commands

```sh
make install                  # build and replace /Applications/Finch.app
make test URL="https://…"     # which browser a URL resolves to; opens nothing
make trace                    # stream the route log
make loc                      # code lines, comments excluded
```

`Finch --bench <n> <url>` times `n` resolves in-process.
`FINCH_CONFIG=<path>` points `--test` and `--bench` at a config other than
`~/.finch.js`.
