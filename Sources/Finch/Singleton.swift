import Foundation

// Chromium's process-singleton protocol, spoken directly.
//
// macOS drops launch arguments when the target app is already running, so
// `--profile-directory` cannot reach a live Chrome through LaunchServices. The
// documented way round it — the one Finicky, grinch and chowser all use — is to
// start a *second* browser process, which relays its command line to the first
// one over a Unix socket and exits. That relay process start is the entire cost
// of a profile-routed link: ~110ms warm, and seconds when the browser's
// framework has fallen out of the page cache. See docs/latency.md.
//
// There is no need for the middleman. Finch writes to the same socket itself,
// measured at 0.1-0.3ms and verified to land in the requested profile.
//
// Protocol, from chrome/browser/process_singleton_posix.cc:
//   ->  "START\0<cwd>\0<argv0>\0<argv1>…"  then shutdown(SHUT_WR)
//   <-  "ACK"       the running browser accepted the command line
//   <-  "SHUTDOWN"  it is quitting, so the caller should launch normally
// The receiver drops the first two fields and treats the rest as argv, which is
// why argv[0] has to be the browser executable.
//
// This is an internal detail of a program Finch does not own, so it is written
// as an optimisation and never as a requirement: every failure, including an
// unrecognised reply, falls back to spawning a real relay process.

enum Singleton {

    enum Outcome {
        case ack
        /// Reached the browser, but it did not take the command line.
        case declined(String)
        /// Never got a message in. Falling back cannot double-open anything.
        case unreachable(String)
    }

    /// Where a browser keeps `SingletonSocket`, under `~/Library/Application
    /// Support`. Only Chrome is listed because only Chrome is verified; any
    /// other bundle id with launch args takes the relay path, which is what
    /// every other router does anyway.
    static let dataDirs: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
    ]

    /// The symlink Chromium leaves in the user data directory. Deliberately not
    /// resolved: it points into `/var/folders/…`, which is long enough to risk
    /// the 104-byte `sun_path` limit, and connect() follows symlinks anyway.
    static func socketPath(bundleId: String) -> String? {
        guard let dir = dataDirs[bundleId] else { return nil }
        let path = NSHomeDirectory() + "/Library/Application Support/" + dir + "/SingletonSocket"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// `argv` must start with the browser's executable path.
    static func send(argv: [String], to path: String, timeoutMs: Int32 = 1_000) -> Outcome {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { return .unreachable("path over sun_path limit") }
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.withCString { strncpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, capacity - 1) }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .unreachable("socket(): errno \(errno)") }
        defer { close(fd) }

        // A wedged browser must not hold this thread. The healthy case answers
        // in well under a millisecond, so the timeout only ever fires on a
        // browser that would have hung the relay path too.
        var tv = timeval(tv_sec: Int(timeoutMs / 1_000),
                         tv_usec: suseconds_t((timeoutMs % 1_000) * 1_000))
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return .unreachable("connect(): errno \(errno)") }

        let message = Array((["START", "/"] + argv).joined(separator: "\0").utf8)
        var sent = 0
        while sent < message.count {
            let n = message[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return .unreachable("write(): errno \(errno)") }
            sent += n
        }
        // The receiver reads to EOF, so the half-close *is* the terminator.
        guard shutdown(fd, SHUT_WR) == 0 else { return .unreachable("shutdown(): errno \(errno)") }

        var buf = [UInt8](repeating: 0, count: 16)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else { return .declined("no reply (errno \(errno))") }
        let reply = String(decoding: buf[0 ..< n], as: UTF8.self)
        return reply == "ACK" ? .ack : .declined(reply)
    }
}
