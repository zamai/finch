import Foundation

// JS prelude evaluated once at config load: a minimal URL polyfill
// (JavaScriptCore has no DOM, so `URL` does not otherwise exist), the `domain`
// helper, and CommonJS scaffolding.
//
// `domain` returns DATA, not a function, so the engine compiles it to a native
// host check at load time and matching never re-enters JavaScript.

let JS_PRELUDE = """
// ---------- URL polyfill (lazy searchParams, no DOM, no IDNA) ----------
(function(g) {
  if (g.URL) return;
  function URL(href) {
    var m = /^([a-z][a-z0-9+.-]*:)(?:\\/\\/(?:([^:@\\/]*)(?::([^@\\/]*))?@)?([^:\\/?#]*)(?::(\\d+))?)?([^?#]*)(\\?[^#]*)?(#.*)?$/i.exec(href);
    if (!m) throw new TypeError("Invalid URL: " + href);
    this.href = href;
    this.protocol = m[1];
    this.username = m[2] || "";
    this.password = m[3] || "";
    this.hostname = m[4] || "";
    this.port = m[5] || "";
    this.host = this.hostname + (this.port ? ":" + this.port : "");
    this.pathname = m[6] || "";
    this.search = m[7] || "";
    this.hash = m[8] || "";
    var sp = null;
    var self = this;
    Object.defineProperty(this, "searchParams", { get: function() {
      if (sp) return sp;
      sp = { _m: {},
        get: function(k) { return this._m[k] ? this._m[k][0] : null; },
        getAll: function(k) { return this._m[k] || []; },
        has: function(k) { return !!this._m[k]; },
        set: function(k, v) { this._m[k] = [String(v)]; },
        append: function(k, v) { (this._m[k] = this._m[k] || []).push(String(v)); },
        delete: function(k) { delete this._m[k]; },
        toString: function() { var p=[],k,i; for(k in this._m) for(i=0;i<this._m[k].length;i++) p.push(encodeURIComponent(k)+"="+encodeURIComponent(this._m[k][i])); return p.join("&"); }
      };
      if (self.search.length > 1) {
        var pairs = self.search.slice(1).split("&");
        for (var i=0;i<pairs.length;i++) {
          if (!pairs[i]) continue;
          var kv = pairs[i].split("=");
          sp.append(decodeURIComponent(kv[0]), kv[1] ? decodeURIComponent(kv[1].replace(/\\+/g, ' ')) : "");
        }
      }
      return sp;
    }});
  }
  g.URL = URL;
})(this);

// ---------- Marker helper (compiled to native by Swift) ----------

// Match URLs whose hostname is one of the given hosts, or a subdomain thereof.
//   domain("github.com")           → matches github.com, *.github.com
//   domain("a.com", "b.com")       → matches either
function domain() {
  var hosts = [];
  for (var i = 0; i < arguments.length; i++) hosts.push(String(arguments[i]).toLowerCase());
  return { __type: "domain", hosts: hosts };
}

// ---------- CommonJS scaffolding ----------
var __finchModule = { exports: {} };
"""

// Wrap user source so module/exports are scoped locally and don't pollute globals.
func wrapUserConfig(_ src: String) -> String {
    return "(function(module, exports) {\n\(src)\n})(__finchModule, __finchModule.exports);"
}
