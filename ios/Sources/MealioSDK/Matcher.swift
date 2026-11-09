// PROTOCOL.md "Matcher". Mirrors packages/core/src/matcher.ts.

import Foundation

/// Page messages keep containers to this depth; deeper ones come back empty.
let messageDepth = 512

/// Parse one posted message. Anything that is not a JSON object is dropped.
/// Accepts JSON text (what the bridge shim posts) or an already-parsed value.
/// Containers deeper than 512 levels are kept empty, never built, so a page
/// cannot post a message deep enough to exhaust the stack.
public func parseMessage(_ raw: Any?) -> JSONMessage? {
    guard let raw = raw else { return nil }
    switch raw {
    case let s as String:
        return JSONValue.parse(s, keep: messageDepth)?.objectValue
    case let v as JSONValue:
        return v.objectValue
    case let d as [String: Any]:
        guard JSONSerialization.isValidJSONObject(d),
              let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return JSONValue.parse(data, keep: messageDepth)?.objectValue
    default:
        return nil
    }
}

/// `msg.type === m.type`, every `eq` field strictly equal, every `ne` field
/// not equal. A missing field is "not equal".
public func matches(_ msg: JSONMessage, _ m: Matcher) -> Bool {
    guard msg["type"]?.stringValue == m.type else { return false }
    if let eq = m.eq {
        for (k, want) in eq {
            guard let have = msg[k], have.jsEquals(want) else { return false }
        }
    }
    if let ne = m.ne {
        for (k, avoid) in ne {
            if let have = msg[k], have.jsEquals(avoid) { return false }
        }
    }
    return true
}

public func matchesAny(_ msg: JSONMessage, _ list: [Matcher]) -> Bool {
    list.contains { matches(msg, $0) }
}
