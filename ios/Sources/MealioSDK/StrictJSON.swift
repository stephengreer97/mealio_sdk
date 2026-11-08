// JSON text read exactly as JavaScript's JSON.parse reads it, so the SDK and
// the TS reference agree on what is JSON (the guard's body rule, envelopes,
// posted messages). Foundation's readers differ: they stop at 512 levels of
// nesting and refuse a lone surrogate escape, which JSON.parse accepts.
//
// - Whitespace is space, tab, LF and CR only.
// - Strings: no raw control characters; escapes are \" \\ \/ \b \f \n \r \t
//   and \u with exactly four ASCII hex digits. A surrogate pair joins; a lone
//   surrogate is accepted, as JSON.parse does, and becomes U+FFFD (a Swift
//   String cannot hold one).
// - Numbers: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?. Too large is
//   infinity, as in JavaScript.
// - A repeated key: the last one wins.
// - No nesting limit: the parser keeps its own stack, not the call stack.

import Foundation

enum StrictJSON {
    /// Parse `text`. Nil when JSON.parse would throw. Containers nested deeper
    /// than `keep` levels are checked in full but come back empty, so a caller
    /// that reads only the top of a body never builds a deep tree.
    static func parse(_ text: String, keep: Int = Int.max) -> JSONValue? {
        var p = StrictJSONParser(bytes: Array(text.utf8), keep: keep)
        return p.run()
    }
}

private struct StrictJSONParser {
    private enum Frame {
        case array([JSONValue], keeps: Bool)
        case object([String: JSONValue], key: String, keeps: Bool)
    }

    private let b: [UInt8]
    private let keep: Int
    private var i = 0

    init(bytes: [UInt8], keep: Int) {
        b = bytes
        self.keep = keep
    }

    private var peek: UInt8? { i < b.count ? b[i] : nil }

    private mutating func skipSpace() {
        while i < b.count {
            switch b[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    mutating func run() -> JSONValue? {
        var stack: [Frame] = []
        skipSpace()
        while true {
            // A value starts at b[i].
            guard let c = peek else { return nil }
            let keeps = stack.count < keep
            var value: JSONValue
            switch c {
            case UInt8(ascii: "{"):
                i += 1
                skipSpace()
                if peek == UInt8(ascii: "}") {
                    i += 1
                    value = .object([:])
                } else {
                    guard let key = memberKey() else { return nil }
                    stack.append(.object([:], key: key, keeps: keeps))
                    continue
                }
            case UInt8(ascii: "["):
                i += 1
                skipSpace()
                if peek == UInt8(ascii: "]") {
                    i += 1
                    value = .array([])
                } else {
                    stack.append(.array([], keeps: keeps))
                    continue
                }
            case UInt8(ascii: "\""):
                guard let s = string() else { return nil }
                value = .string(s)
            case UInt8(ascii: "t"):
                guard word("true") else { return nil }
                value = .bool(true)
            case UInt8(ascii: "f"):
                guard word("false") else { return nil }
                value = .bool(false)
            case UInt8(ascii: "n"):
                guard word("null") else { return nil }
                value = .null
            default:
                guard let n = number() else { return nil }
                value = n
            }
            // Hand the value to its container; close containers that end here.
            var next = false
            while !next {
                skipSpace()
                guard let top = stack.popLast() else {
                    return i == b.count ? value : nil
                }
                switch top {
                case .array(var a, let keeps):
                    if keeps { a.append(value) }
                    if peek == UInt8(ascii: ",") {
                        i += 1
                        skipSpace()
                        stack.append(.array(a, keeps: keeps))
                        next = true
                    } else if peek == UInt8(ascii: "]") {
                        i += 1
                        value = .array(a)
                    } else {
                        return nil
                    }
                case .object(var o, let key, let keeps):
                    if keeps { o[key] = value }
                    if peek == UInt8(ascii: ",") {
                        i += 1
                        skipSpace()
                        guard let k = memberKey() else { return nil }
                        stack.append(.object(o, key: k, keeps: keeps))
                        next = true
                    } else if peek == UInt8(ascii: "}") {
                        i += 1
                        value = .object(o)
                    } else {
                        return nil
                    }
                }
            }
        }
    }

    /// `"key"` then `:`, leaving `i` at the value.
    private mutating func memberKey() -> String? {
        guard peek == UInt8(ascii: "\""), let k = string() else { return nil }
        skipSpace()
        guard peek == UInt8(ascii: ":") else { return nil }
        i += 1
        skipSpace()
        return k
    }

    private mutating func word(_ w: String) -> Bool {
        let u = Array(w.utf8)
        guard i + u.count <= b.count else { return false }
        for k in 0..<u.count where b[i + k] != u[k] { return false }
        i += u.count
        return true
    }

    private static func hexValue(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(c - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(c - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }

    /// Four ASCII hex digits at `at`.
    private func hex4(_ at: Int) -> UInt32? {
        guard at + 4 <= b.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            guard let d = StrictJSONParser.hexValue(b[at + k]) else { return nil }
            v = v << 4 | d
        }
        return v
    }

    private static func append(_ scalar: UInt32, to out: inout [UInt8]) {
        let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
        out.append(contentsOf: Array(String(Character(u)).utf8))
    }

    /// A string starting at the opening quote.
    private mutating func string() -> String? {
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if c < 0x20 { return nil }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            guard i + 1 < b.count else { return nil }
            let e = b[i + 1]
            i += 2
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard let u = hex4(i) else { return nil }
                i += 4
                if u >= 0xD800 && u <= 0xDBFF,
                   i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u"),
                   let low = hex4(i + 2), low >= 0xDC00 && low <= 0xDFFF {
                    i += 6
                    StrictJSONParser.append(0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00), to: &out)
                } else {
                    // A lone surrogate is not a scalar: U+FFFD.
                    StrictJSONParser.append(u, to: &out)
                }
            default:
                return nil
            }
        }
        return nil
    }

    private func isDigit(_ at: Int) -> Bool {
        at < b.count && b[at] >= UInt8(ascii: "0") && b[at] <= UInt8(ascii: "9")
    }

    private mutating func number() -> JSONValue? {
        let start = i
        var whole = true
        if peek == UInt8(ascii: "-") { i += 1 }
        guard isDigit(i) else { return nil }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else {
            while isDigit(i) { i += 1 }
        }
        if peek == UInt8(ascii: ".") {
            whole = false
            i += 1
            guard isDigit(i) else { return nil }
            while isDigit(i) { i += 1 }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            whole = false
            i += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { i += 1 }
            guard isDigit(i) else { return nil }
            while isDigit(i) { i += 1 }
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        if whole, let n = Int(text) { return .int(n) }
        guard let d = Double(text) else { return nil }
        // A whole number written with a fraction or exponent ("2.0", "1e3")
        // is an Int, as Foundation's decoder had it.
        if d.isFinite, d.rounded() == d, abs(d) < 9.0e15 { return .int(Int(d)) }
        return .double(d)
    }
}
