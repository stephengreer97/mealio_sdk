// JSON text for JSONValue, without a depth limit. Foundation's JSON writer
// refuses nesting past 512 levels, and a page message may already be 513 deep
// (see messageDepth) before the step body wraps it in four more. This writer
// keeps its own stack, so depth costs heap, never call stack, and its output
// for ordinary values is byte for byte what JSONEncoder writes (macOS 15 /
// iOS 18 Foundation): numbers, string escapes, and no whitespace.

import Foundation

/// A value as the writer walks it. `.ordered` is an object whose keys are
/// written in the order given (a struct's declaration order, as JSONEncoder
/// writes a struct); `.value` objects are written in dictionary order, as
/// JSONEncoder writes a dictionary.
indirect enum JSONNode {
    case value(JSONValue)
    case ordered([(String, JSONNode)])
    case list([JSONNode])
}

/// What can be written by `JSONWriter` instead of JSONEncoder: every request
/// body that may carry a page message.
protocol JSONNodeConvertible {
    var jsonNode: JSONNode { get }
}

extension JSONValue: JSONNodeConvertible {
    var jsonNode: JSONNode { .value(self) }
}

struct JSONWriter {
    /// JSONEncoder's `.sortedKeys`. Off for request bodies, as today.
    var sortedKeys = false
    /// JSONEncoder writes `/` as `\/` unless told `.withoutEscapingSlashes`.
    /// Off: the client's encoder has always set `.withoutEscapingSlashes`.
    var escapeSlashes = false

    private enum Frame {
        case values([JSONValue], Int)
        case pairs([(String, JSONValue)], Int)
        case nodes([JSONNode], Int)
        case nodePairs([(String, JSONNode)], Int)
    }

    func data(_ node: JSONNode) throws -> Data {
        Data(try bytes(node))
    }

    func data(_ value: JSONValue) throws -> Data {
        Data(try bytes(.value(value)))
    }

    func string(_ value: JSONValue) throws -> String {
        String(decoding: try bytes(.value(value)), as: UTF8.self)
    }

    func bytes(_ root: JSONNode) throws -> [UInt8] {
        var out: [UInt8] = []
        var stack: [Frame] = []
        var next: JSONNode? = root
        while true {
            if let n = next {
                next = nil
                switch n {
                case .value(let v):
                    switch v {
                    case .null: out.append(contentsOf: Array("null".utf8))
                    case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
                    case .int(let i): out.append(contentsOf: Array(String(i).utf8))
                    case .double(let d):
                        let t = try JSONWriter.number(d)
                        out.append(contentsOf: Array(t.utf8))
                    case .string(let s): writeString(s, into: &out)
                    case .array(let a):
                        out.append(UInt8(ascii: "["))
                        stack.append(.values(a, 0))
                    case .object(let o):
                        out.append(UInt8(ascii: "{"))
                        var pairs: [(String, JSONValue)] = o.map { ($0.key, $0.value) }
                        if sortedKeys { pairs.sort { JSONWriter.before($0.0, $1.0) } }
                        stack.append(.pairs(pairs, 0))
                    }
                case .ordered(let p):
                    out.append(UInt8(ascii: "{"))
                    var pairs = p
                    if sortedKeys { pairs.sort { JSONWriter.before($0.0, $1.0) } }
                    stack.append(.nodePairs(pairs, 0))
                case .list(let a):
                    out.append(UInt8(ascii: "["))
                    stack.append(.nodes(a, 0))
                }
            }
            guard let top = stack.popLast() else { break }
            switch top {
            case .values(let a, let i):
                if i == a.count { out.append(UInt8(ascii: "]")); continue }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                stack.append(.values(a, i + 1))
                next = .value(a[i])
            case .nodes(let a, let i):
                if i == a.count { out.append(UInt8(ascii: "]")); continue }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                stack.append(.nodes(a, i + 1))
                next = a[i]
            case .pairs(let p, let i):
                if i == p.count { out.append(UInt8(ascii: "}")); continue }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(p[i].0, into: &out)
                out.append(UInt8(ascii: ":"))
                stack.append(.pairs(p, i + 1))
                next = .value(p[i].1)
            case .nodePairs(let p, let i):
                if i == p.count { out.append(UInt8(ascii: "}")); continue }
                if i > 0 { out.append(UInt8(ascii: ",")) }
                writeString(p[i].0, into: &out)
                out.append(UInt8(ascii: ":"))
                stack.append(.nodePairs(p, i + 1))
                next = p[i].1
            }
        }
        return out
    }

    /// JSONEncoder's number text: `description`, less a trailing ".0".
    /// NaN and infinity throw, as JSONEncoder's default strategy does.
    static func number(_ d: Double) throws -> String {
        guard d.isFinite else {
            throw EncodingError.invalidValue(d, EncodingError.Context(
                codingPath: [], debugDescription: "Unable to encode Double.\(d) directly in JSON."))
        }
        var s = d.description
        if s.hasSuffix(".0") { s.removeLast(2) }
        return s
    }

    /// JSONEncoder's `.sortedKeys` order on current Foundation: plain UTF-16
    /// code unit order ("A" < "_" < "a", "a1" < "a10" < "a2").
    static func before(_ a: String, _ b: String) -> Bool {
        a.utf16.lexicographicallyPrecedes(b.utf16)
    }

    private static let hex: [UInt8] = Array("0123456789abcdef".utf8)

    /// JSONEncoder's escapes: quote, backslash, optionally slash, the five
    /// short control escapes, other controls as lowercase \u00xx, everything
    /// else (U+007F and all non-ASCII included) as its UTF-8 bytes.
    private func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for b in s.utf8 {
            switch b {
            case 0x22: out.append(0x5C); out.append(0x22)
            case 0x5C: out.append(0x5C); out.append(0x5C)
            case 0x2F:
                if escapeSlashes { out.append(0x5C) }
                out.append(0x2F)
            case 0x08: out.append(0x5C); out.append(UInt8(ascii: "b"))
            case 0x0C: out.append(0x5C); out.append(UInt8(ascii: "f"))
            case 0x0A: out.append(0x5C); out.append(UInt8(ascii: "n"))
            case 0x0D: out.append(0x5C); out.append(UInt8(ascii: "r"))
            case 0x09: out.append(0x5C); out.append(UInt8(ascii: "t"))
            case 0x00..<0x20:
                out.append(contentsOf: [0x5C, UInt8(ascii: "u"), UInt8(ascii: "0"), UInt8(ascii: "0"),
                                        JSONWriter.hex[Int(b >> 4)], JSONWriter.hex[Int(b & 0xF)]])
            default:
                out.append(b)
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

public extension JSONValue {
    /// JSON text for this value, as JSONEncoder with `.withoutEscapingSlashes`
    /// writes it, but at any depth: no recursion and no 512-level limit.
    /// Throws only for NaN or infinity, as JSONEncoder does.
    func jsonData() throws -> Data {
        try JSONWriter().data(self)
    }
}

// MARK: - The step body, which carries page messages

extension InstructionResult: JSONNodeConvertible {
    /// The synthesized Encodable's shape: declared order, nil fields left out.
    var jsonNode: JSONNode {
        var p: [(String, JSONNode)] = [("id", .value(.string(id))), ("ok", .value(.bool(ok))), ("ms", .value(.int(ms)))]
        if let v = skipped { p.append(("skipped", .value(.bool(v)))) }
        if let v = error { p.append(("error", .value(.string(v)))) }
        if let v = finalUrl { p.append(("finalUrl", .value(.string(v)))) }
        if let v = messages { p.append(("messages", .list(v.map { .value(.object($0)) }))) }
        if let v = timedOut { p.append(("timedOut", .value(.bool(v)))) }
        if let v = outcome { p.append(("outcome", .value(.string(v.rawValue)))) }
        if let v = status { p.append(("status", .value(.int(v)))) }
        if let v = headers { p.append(("headers", .value(.object(v.mapValues { .string($0) })))) }
        if let v = body { p.append(("body", .value(.string(v)))) }
        if let v = truncated { p.append(("truncated", .value(.bool(v)))) }
        return .ordered(p)
    }
}

extension StepRequest: JSONNodeConvertible {
    var jsonNode: JSONNode {
        .ordered([("seq", .value(.int(seq))), ("results", .list(results.map { $0.jsonNode }))])
    }
}
