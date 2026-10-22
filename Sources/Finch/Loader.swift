import Foundation
import JavaScriptCore

// Loads ~/.finch.js, evaluates it in a JSContext with helpers + URL polyfill
// pre-injected, and returns the module.exports JSValue plus the context that
// owns it (must be kept alive — JSValues retain their context).

struct LoadedConfig {
    let exports: JSValue   // the user's module.exports
    let ctx: JSContext     // owns all JSValues; must outlive the engine
}

func loadConfig() -> LoadedConfig? {
    // FINCH_CONFIG lets `--test` try a config without touching the live one.
    let path = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FINCH_CONFIG"]
                   ?? NSHomeDirectory() + "/.finch.js")
    guard let source = try? String(contentsOf: path, encoding: .utf8) else {
        Trace.shared.report("no config at \(path.path)")
        return nil
    }

    let ctx = JSContext()!
    var lastError: String?
    ctx.exceptionHandler = { _, ex in
        let line = ex?.objectForKeyedSubscript("line").toString() ?? "?"
        let msg  = ex?.toString() ?? "unknown"
        lastError = "\(msg) (line \(line))"
        Trace.shared.report("js error: \(lastError ?? "")")
    }

    // Inject prelude (URL polyfill + helpers + module scaffolding)
    ctx.evaluateScript(JS_PRELUDE)
    if lastError != nil { return nil }

    // Evaluate user config wrapped in IIFE so module/exports are scoped
    ctx.evaluateScript(wrapUserConfig(source))
    if lastError != nil { return nil }

    guard let mod = ctx.objectForKeyedSubscript("__finchModule"),
          let exports = mod.objectForKeyedSubscript("exports"),
          !exports.isUndefined && !exports.isNull
    else {
        Trace.shared.report("config did not export anything (use module.exports = {...})")
        return nil
    }

    return LoadedConfig(exports: exports, ctx: ctx)
}
