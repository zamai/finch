import Foundation
import os.log

// Where the time goes between a click and a browser window.
//
// The hot path stores nothing but integers: each `mark` is one monotonic clock
// read plus an array append, so measuring costs well under a microsecond and
// never touches the filesystem on the main thread. Formatting and IO happen
// afterwards on `sink`, off the main thread — a slow disk must not become the
// latency it was added to measure.
//
// Two outputs, because they answer different questions:
//   os_log           always on, and free when nobody is listening.
//                    `make trace` streams it live.
//   ~/.finch.log     one line per route, so a slow open an hour ago is still
//                    there to look at. Rotated at a megabyte and never read
//                    back, so it cannot grow without bound.

@inline(__always)
func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) }

/// Stage marks for one routed URL. A class, not a struct, and locked, because
/// the last mark arrives from `NSWorkspace`'s completion handler on another
/// queue while the main thread may still be marking the call that scheduled it.
/// An uncontended `os_unfair_lock` is tens of nanoseconds — cheaper than the
/// clock read it guards.
final class RouteTrace {
    private let t0: UInt64
    /// Wall clock at t0, so an external harness can measure the part of the
    /// latency that happens before Finch is involved at all.
    private let wall: Double
    private var marks: [(String, UInt64)] = []
    private var lock = os_unfair_lock()

    init() {
        t0 = monotonicNs()
        wall = Date().timeIntervalSince1970
        marks.reserveCapacity(8)
    }

    func mark(_ name: String) {
        let t = monotonicNs()
        os_unfair_lock_lock(&lock)
        marks.append((name, t))
        os_unfair_lock_unlock(&lock)
    }

    /// Hand the finished trace to the sink. Safe to call from any queue.
    func emit(_ summary: String) {
        os_unfair_lock_lock(&lock)
        let marks = self.marks
        os_unfair_lock_unlock(&lock)
        let t0 = self.t0, wall = self.wall
        Trace.shared.write {
            var line = String(format: "%.6f", wall) + " "
            var prev = t0
            var stages = ""
            for (name, t) in marks {
                stages += " \(name)=\(Trace.ms(t - prev))"
                prev = t
            }
            line += "total=\(Trace.ms(prev - t0))" + stages + " " + summary
            return line
        }
    }
}

final class Trace {
    static let shared = Trace()

    private static let log = OSLog(subsystem: "com.finch.browser", category: "route")
    private static let maxBytes: UInt64 = 1 << 20

    private let sink = DispatchQueue(label: "com.finch.browser.trace", qos: .utility)
    private let path = NSHomeDirectory() + "/.finch.log"

    static func ms(_ ns: UInt64) -> String {
        String(format: "%.1fms", Double(ns) / 1_000_000)
    }

    /// `body` runs on the sink queue — string building is work the main thread
    /// should not be doing either.
    func write(_ body: @escaping () -> String) {
        sink.async { [path] in
            let line = body()
            os_log("%{public}s", log: Self.log, type: .info, line)
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64,
               size > Self.maxBytes {
                try? FileManager.default.removeItem(atPath: path + ".1")
                try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
            }
            guard let fh = FileHandle(forWritingAtPath: path) else {
                try? data.write(to: URL(fileURLWithPath: path))
                return
            }
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        }
    }
}
