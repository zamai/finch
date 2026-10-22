import Foundation
import JavaScriptCore

struct BrowserSpec {
    let bundleId: String
    let args: [String]
}

struct Resolution {
    let browser: BrowserSpec
    let url: URL
}

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// The config is compiled once, at load, into native matchers. JavaScript is
// only re-entered for a rewrite's `url: (href) => …` function, and only when
// that rewrite's matcher has already hit.

private enum Matcher {
    case regex(NSRegularExpression)   // /literal/, against the full URL
    case domain([String])             // "host" or domain(…): the host or any subdomain
}

private struct Rewrite {
    let matchers: [Matcher]           // any one is enough
    let fn: JSValue                   // (href) => string
}

private struct Rule {
    let matchers: [Matcher]
    let browser: BrowserSpec
}

final class Engine {
    private let defaultBrowser: BrowserSpec
    private let rewrites: [Rewrite]
    private let rules: [Rule]
    private let ctx: JSContext        // owns the rewrite functions

    /// Throws on anything it does not understand, rather than skipping it: a
    /// rule that silently never matches sends links to the wrong profile, and
    /// a rejected reload keeps the previous engine running.
    init(loaded: LoadedConfig) throws {
        ctx = loaded.ctx
        let exports = loaded.exports

        var browsers: [String: BrowserSpec] = [:]
        let b = exports.objectForKeyedSubscript("browsers")!
        if !b.isUndefined {
            guard let dict = b.toDictionary() as? [String: Any] else {
                throw ConfigError("`browsers` must be an object")
            }
            for (name, val) in dict {
                guard let spec = browserSpec(val) else {
                    throw ConfigError("browsers.\(name): expected a bundle id or { id, args }")
                }
                browsers[name] = spec
            }
        }
        func browser(_ v: JSValue, _ at: String) throws -> BrowserSpec {
            guard v.isString, let name = v.toString(), !name.isEmpty else {
                throw ConfigError("\(at): expected a browser name or bundle id")
            }
            return browsers[name] ?? BrowserSpec(bundleId: name, args: [])
        }

        defaultBrowser = try browser(exports.objectForKeyedSubscript("default"), "default")

        rewrites = try list(exports.objectForKeyedSubscript("rewrite"), "rewrite").enumerated().map { i, item in
            let at = "rewrite[\(i)]"
            let fn = item.objectForKeyedSubscript("url")!
            guard isFunction(fn) else { throw ConfigError("\(at): `url` must be a function (href) => string") }
            return Rewrite(matchers: try matchers(item.objectForKeyedSubscript("match"), at), fn: fn)
        }

        rules = try list(exports.objectForKeyedSubscript("rules"), "rules").enumerated().map { i, item in
            let at = "rules[\(i)]"
            return Rule(matchers: try matchers(item.objectForKeyedSubscript("match"), at),
                        browser: try browser(item.objectForKeyedSubscript("open"), "\(at).open"))
        }
    }

    // MARK: Hot path

    func resolve(_ raw: String) -> Resolution {
        var current = raw
        for rw in rewrites where anyMatch(rw.matchers, current) {
            if let out = rw.fn.call(withArguments: [current]), out.isString {
                current = out.toString()
            }
        }
        let browser = rules.first { anyMatch($0.matchers, current) }?.browser ?? defaultBrowser
        return Resolution(browser: browser, url: URL(string: current) ?? URL(string: raw)!)
    }

    private func anyMatch(_ matchers: [Matcher], _ url: String) -> Bool {
        matchers.contains { m in
            switch m {
            case .regex(let re):
                return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            case .domain(let hosts):
                guard let host = quickHost(url) else { return false }
                return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
            }
        }
    }
}

// MARK: - Compilation

private func browserSpec(_ val: Any) -> BrowserSpec? {
    if let s = val as? String, !s.isEmpty { return BrowserSpec(bundleId: s, args: []) }
    if let d = val as? [String: Any], let id = d["id"] as? String, !id.isEmpty {
        return BrowserSpec(bundleId: id, args: d["args"] as? [String] ?? [])
    }
    return nil
}

/// The elements of a JS array; `undefined` reads as empty.
private func list(_ v: JSValue, _ at: String) throws -> [JSValue] {
    if v.isUndefined { return [] }
    guard v.isArray else { throw ConfigError("`\(at)` must be an array") }
    let n = Int(v.objectForKeyedSubscript("length").toInt32())
    return (0 ..< n).map { v.atIndex($0) }
}

/// `match` is one pattern or an array of them, any of which may hit.
private func matchers(_ v: JSValue, _ at: String) throws -> [Matcher] {
    let patterns = v.isArray ? try list(v, at) : [v]
    guard !patterns.isEmpty else { throw ConfigError("\(at): `match` is empty") }
    return try patterns.map { p in
        if p.isString {
            return .domain([p.toString().lowercased()])
        }
        if p.isObject, p.objectForKeyedSubscript("__type").toString() == "domain",
           let hosts = p.objectForKeyedSubscript("hosts").toArray() as? [String] {
            return .domain(hosts)
        }
        if p.isObject, p.isInstance(of: p.context.objectForKeyedSubscript("RegExp")),
           let re = try? NSRegularExpression(pattern: p.objectForKeyedSubscript("source").toString(),
                                             options: .caseInsensitive) {
            return .regex(re)
        }
        throw ConfigError("\(at): unsupported match \(p.toString() ?? "?") — use \"host\", domain(…) or /regex/")
    }
}

private func isFunction(_ v: JSValue) -> Bool {
    v.isObject && v.isInstance(of: v.context.objectForKeyedSubscript("Function"))
}

/// Lowercased host of a URL string, without URLComponents' allocations.
@inline(__always)
private func quickHost(_ url: String) -> String? {
    var s = Substring(url)
    if let r = s.range(of: "://") { s = s[r.upperBound...] }
    if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = s[..<i] }
    if let at = s.lastIndex(of: "@") { s = s[s.index(after: at)...] }
    if let colon = s.lastIndex(of: ":") { s = s[..<colon] }
    return s.isEmpty ? nil : s.lowercased()
}
