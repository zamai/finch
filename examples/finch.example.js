// Finch browser router — see https://github.com/anthony/finch
//
// Reload after editing:  kill -HUP $(pgrep -f Finch.app/Contents/MacOS/Finch)

module.exports = {

  default: "zen",

  browsers: {
    zen:    "app.zen-browser.zen",
    prisma: "com.talon-sec.Work",

    // A browser can carry launch args. For Chromium profiles this is the
    // point: macOS drops launch arguments for an app that is already running,
    // so Finch delivers them over the browser's process-singleton socket.
    // `dataDir` (under ~/Library/Application Support) says where to find that
    // socket, and is only needed for a Chromium browser Finch does not already
    // know — Chrome, Chromium, Brave, Edge and Vivaldi are built in. Without
    // it the link still opens, just via a slower second browser process.
    chromeWork: {
      id: "com.google.Chrome",
      args: ["--profile-directory=Profile 1"],
    },
  },

  // Rewrites run in order, all matching ones apply.
  rewrite: [
    strip("utm_source", "utm_medium", "utm_campaign", "utm_term",
          "utm_content", "fbclid", "gclid", "mc_eid"),
  ],

  // First matching rule wins. Bare strings are hostname matches
  // (matches the host exactly OR any subdomain).
  rules: [
    { match: domain(
        "paymentology.atlassian.net",
        "tutuka.atlassian.net",
        "paymen.sharepoint.com",
        "hibob.com",
        "pagerduty.com",
        "datadoghq.com",
        "miro.com",
        "zoom.us",
      ),
      open: "prisma",
    },

    // Path-specific routing: regex matches full URL
    { match: /github\.com\/(paymentology|tutuka)\//, open: "prisma" },
  ],

};
