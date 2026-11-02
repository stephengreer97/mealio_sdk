package co.mealio.sdk

import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

// Envelope checks. Port of packages/core/src/verify.ts, with the same failure
// reasons: shape, unknown_kid, signature, json, version, expired, kind, job,
// seq, empty, too_many, unsupported_op.

/** An envelope the SDK must refuse. `why` is one of the reasons above. */
class EnvelopeException(val why: String) : Exception("bad_envelope: $why") {
    val code: String get() = "bad_envelope"
}

private const val ED25519_SIGNATURE_SIZE = 64

private const val B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

/**
 * base64 (standard or url-safe, padded or not) to bytes. Hand written because
 * android.util.Base64 is a stub in JVM unit tests and java.util.Base64 needs
 * API 26.
 */
fun base64ToBytes(s: String): ByteArray {
    val out = java.io.ByteArrayOutputStream(s.length * 3 / 4)
    var buf = 0
    var bits = 0
    for (raw in s) {
        val ch = when (raw) {
            '-' -> '+'
            '_' -> '/'
            else -> raw
        }
        val idx = B64.indexOf(ch)
        if (idx < 0) continue // padding, whitespace and anything else are skipped
        buf = ((buf shl 6) or idx) and 0xFFFFFF
        bits += 6
        if (bits >= 8) {
            bits -= 8
            out.write((buf shr bits) and 0xff)
        }
    }
    return out.toByteArray()
}

/** Ed25519 check of `sig` over `message`. Any malformed input is just "not valid". */
internal fun ed25519Verify(publicKeyB64: String, sigB64: String, message: ByteArray): Boolean = try {
    val pub = base64ToBytes(publicKeyB64)
    val sig = base64ToBytes(sigB64)
    if (pub.size != Ed25519PublicKeyParameters.KEY_SIZE || sig.size != ED25519_SIGNATURE_SIZE) {
        false
    } else {
        val signer = Ed25519Signer()
        signer.init(false, Ed25519PublicKeyParameters(pub, 0))
        signer.update(message, 0, message.size)
        signer.verifySignature(sig)
    }
} catch (e: Exception) {
    false
}

/**
 * Check the signature over the payload string as received, then parse it.
 * The signature covers the UTF-8 bytes of `payload` exactly; it is never
 * re-serialised. Returns the raw payload object.
 */
@JvmOverloads
fun openEnvelope(env: Envelope?, keys: Map<String, String> = KEYS, nowMs: Long = System.currentTimeMillis()): JSONObject {
    if (env == null) throw EnvelopeException("shape")
    val pub = keys[env.kid] ?: throw EnvelopeException("unknown_kid")
    if (!ed25519Verify(pub, env.sig, env.payload.toByteArray(Charsets.UTF_8))) throw EnvelopeException("signature")
    val parsed: Any = try {
        parseJson(env.payload)
    } catch (e: JSONException) {
        throw EnvelopeException("json")
    }
    // JSON that is not an object has no `v`, so it fails the version check.
    val p = parsed as? JSONObject ?: throw EnvelopeException("version")
    val v = p.opt("v")
    if (v !is Number || v.toDouble() != PROTOCOL_VERSION.toDouble()) throw EnvelopeException("version")
    val exp = p.opt("exp")
    if (exp !is Number || exp.toDouble() + EXP_SKEW_SECONDS < nowMs / 1000.0) throw EnvelopeException("expired")
    return p
}

/** The job and sequence checks for an instruction envelope. */
fun checkInstructions(p: JSONObject, job: String?, lastSeq: Int): InstructionsPayload {
    if (p.opt("kind") != "instructions") throw EnvelopeException("kind")
    val pJob = p.opt("job") as? String
    if (!job.isNullOrEmpty() && pJob != job) throw EnvelopeException("job")
    val seq = p.opt("seq")
    if (seq !is Number || seq.toDouble() != (lastSeq + 1).toDouble()) throw EnvelopeException("seq")
    val list = p.opt("instructions") as? JSONArray
    if (list == null || list.length() == 0) throw EnvelopeException("empty")
    if (list.length() > MAX_INSTRUCTIONS) throw EnvelopeException("too_many")
    val raw = ArrayList<JSONObject>(list.length())
    for (i in 0 until list.length()) {
        val o = list.opt(i) as? JSONObject
        val op = o?.opt("op") as? String
        if (o == null || o.opt("id") !is String || op == null || op !in SUPPORTED_OPS) throw EnvelopeException("unsupported_op")
        raw.add(o)
    }
    return InstructionsPayload(
        v = PROTOCOL_VERSION,
        job = pJob,
        seq = lastSeq + 1,
        exp = (p.opt("exp") as? Number)?.toDouble() ?: 0.0,
        store = p.opt("store") as? String ?: "",
        instructions = raw.map { Instruction.fromJson(it) },
    )
}
