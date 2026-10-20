import Foundation

// The last few routes, in memory only — enough to answer "where did the link I
// just clicked go?". Deliberately not persisted: no file, no rotation, no
// toggle. It dies with the process.

struct RouteEntry {
    let id: Int             // so the timing can be filled in once the open lands
    let opener: String      // bundle id of the app the link came from, or the
                            // sender's executable name; "" if unresolvable
    let original: String    // URL as received
    let final: String       // URL after rewrites
    let bundleId: String    // browser it was sent to ("" = suppressed by `open: null`)
    var ms: Double?         // receive -> browser has it; nil until the open lands

    var suppressed: Bool { bundleId.isEmpty }
    var rewritten: Bool { original != final }
}

final class RouteHistory {
    static let shared = RouteHistory()

    /// How many routes the menu bar remembers.
    private static let capacity = 10

    private var entries: [RouteEntry] = []
    private var nextId = 0

    /// Most recent first.
    var recent: [RouteEntry] { entries.reversed() }

    /// Returns the entry's id, so `finish` can attach the timing later — the
    /// route is recorded before the browser has the URL, which is the number
    /// worth showing.
    func record(opener: String, original: String, final: String, bundleId: String) -> Int {
        nextId += 1
        entries.append(RouteEntry(id: nextId, opener: opener, original: original,
                                  final: final, bundleId: bundleId, ms: nil))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return nextId
    }

    /// Main thread only — the open's completion handler arrives on another
    /// queue, and hops here rather than locking something the menu also reads.
    func finish(_ id: Int, ms: Double) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].ms = ms
    }
}
