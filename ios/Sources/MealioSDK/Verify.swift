// Envelope checks. Mirrors packages/core/src/verify.ts, with the same refusal
// reasons in the same order.

import CryptoKit
import Foundation

/// Why an envelope was refused. The client turns any of these into a
/// `MealioError` with code `bad_envelope` (or `unsupported` for `unsupported_op`).
public struct EnvelopeError: Error, Equatable, CustomStringConvertible {
    public enum Reason: String {
        case shape
        case unknownKid = "unknown_kid"
        case signature
        case json
        case version
        case expired
        case kind
        case job
        case seq
        case empty
        case tooMany = "too_many"
        case unsupportedOp = "unsupported_op"
    }

    public let reason: Reason

    public init(_ reason: Reason) { self.reason = reason }

    /// The reason as the wire string, e.g. "unknown_kid".
    public var why: String { reason.rawValue }
    public var code: String { MealioError.Code.badEnvelope }
    public var description: String { "bad_envelope: \(why)" }
}

private let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

/// base64 (standard or url-safe, padded or not) to bytes. Characters outside
/// the alphabet are skipped, the same as the TS reference.
public func base64ToBytes(_ s: String) -> Data {
    var lookup = [UInt8: UInt32]()
    for (i, c) in base64Alphabet.enumerated() { lookup[c] = UInt32(i) }
    var out = Data()
    var buf: UInt32 = 0
    var bits = 0
    for var ch in s.utf8 {
        if ch == UInt8(ascii: "-") { ch = UInt8(ascii: "+") }
        if ch == UInt8(ascii: "_") { ch = UInt8(ascii: "/") }
        guard let v = lookup[ch] else { continue }
        buf = ((buf << 6) | v) & 0xFFFFFF
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8((buf >> UInt32(bits)) & 0xFF))
        }
    }
    return out
}

/// Check the signature over the payload string as received, then parse it.
///
/// - Parameters:
///   - env: The envelope. Nil when the server sent something that is not an
///     envelope (refused as "shape").
///   - keys: Trusted public keys by kid. Defaults to the production keys.
///   - now: The current time, for the expiry check.
public func openEnvelope(_ env: Envelope?, keys: [String: String] = MealioKeys.all, now: Date = Date()) throws -> Payload {
    guard let env = env else { throw EnvelopeError(.shape) }
    guard let pub = keys[env.kid] else { throw EnvelopeError(.unknownKid) }

    // Verify the exact UTF-8 bytes of the payload string. Never re-serialize.
    let signed = Data(env.payload.utf8)
    var ok = false
    if let key = try? Curve25519.Signing.PublicKey(rawRepresentation: base64ToBytes(pub)) {
        ok = key.isValidSignature(base64ToBytes(env.sig), for: signed)
    }
    if !ok { throw EnvelopeError(.signature) }

    guard let parsed = JSONValue.parse(signed) else { throw EnvelopeError(.json) }
    guard let raw = parsed.objectValue, raw["v"]?.doubleValue == Double(PROTOCOL_VERSION) else {
        throw EnvelopeError(.version)
    }
    guard let exp = raw["exp"]?.doubleValue, exp + EXP_SKEW_SECONDS >= now.timeIntervalSince1970 else {
        throw EnvelopeError(.expired)
    }
    return Payload(raw: raw)
}

/// The job and sequence checks for an instruction envelope.
///
/// - Parameters:
///   - job: The job the SDK is running. Nil or empty skips the job check.
///   - lastSeq: The last `seq` run for this job (0 before the first envelope).
public func checkInstructions(_ p: Payload, job: String?, lastSeq: Int) throws -> InstructionsPayload {
    let raw = p.raw
    if p.kind != "instructions" { throw EnvelopeError(.kind) }
    let payloadJob = raw["job"]?.stringValue
    if let job = job, !job.isEmpty, payloadJob != job { throw EnvelopeError(.job) }
    guard let seq = raw["seq"]?.intValue, seq == lastSeq + 1 else { throw EnvelopeError(.seq) }
    guard let list = raw["instructions"]?.arrayValue, !list.isEmpty else { throw EnvelopeError(.empty) }
    if list.count > MAX_INSTRUCTIONS { throw EnvelopeError(.tooMany) }

    var instructions: [Instruction] = []
    for item in list {
        guard item["id"]?.stringValue != nil, let op = item["op"]?.stringValue, SUPPORTED_OPS.contains(op) else {
            throw EnvelopeError(.unsupportedOp)
        }
        let ins = Instruction(json: item)
        // A known op missing a field it needs cannot be run either.
        if case .unsupported = ins { throw EnvelopeError(.unsupportedOp) }
        instructions.append(ins)
    }
    return InstructionsPayload(
        v: raw["v"]?.intValue ?? PROTOCOL_VERSION,
        job: payloadJob ?? "",
        seq: seq,
        exp: p.exp ?? 0,
        store: raw["store"]?.stringValue ?? "",
        instructions: instructions)
}
