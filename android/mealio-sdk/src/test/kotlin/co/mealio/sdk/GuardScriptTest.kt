package co.mealio.sdk

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// guard-expected.js and bridge-expected.js are the exact strings
// packages/core/src/guard.ts produces. Every SDK must inject the same bytes.
// Regenerate them from the TypeScript if guard.ts changes.
class GuardScriptTest {
    @Test
    fun guardMatchesTheReferenceByteForByte() {
        assertEquals(readResource("guard-expected.js"), GUARD_SCRIPT)
    }

    @Test
    fun bridgeShimMatchesTheReferenceByteForByte() {
        assertEquals(readResource("bridge-expected.js"), BRIDGE_SHIM)
    }

    @Test
    fun guardCarriesTheBlockedPatterns() {
        assertTrue(GUARD_SCRIPT.contains(jsStringLiteral(BLOCKED_PATTERNS.joinToString("|"))))
        assertEquals("\"a\\\"b\\\\c\"", jsStringLiteral("a\"b\\c"))
    }

    // ── 0.6 round 4: the guard in every frame, at document start ─────────

    /** androidx.webkit's rule match for `https://[*.]host` rules. */
    private fun ruleMatches(rule: String, origin: String): Boolean {
        val r = rule.removePrefix("https://")
        val o = origin.removePrefix("https://")
        return if (r.startsWith("*.")) o.endsWith(r.substring(1)) else o == r
    }

    @Test
    fun theGuardGoesIntoEveryStoreFrameAtDocumentStart() {
        val plan = documentStartScripts(LISTENER_BOOTSTRAP_SCRIPT)
        assertEquals(LISTENER_BOOTSTRAP_SCRIPT to setOf("*"), plan[0])
        val (script, rules) = plan[1]
        assertEquals("the guard follows the bootstrap", GUARD_SCRIPT, script)
        for (r in rules) assertTrue(r, Regex("^https://(\\*\\.)?[a-z0-9-]+(\\.[a-z0-9-]+)+$").matches(r))
        assertTrue("not every origin", "*" !in rules)
        for ((store, h) in STORES) for (host in h.hosts + h.authHosts) for (origin in listOf("https://$host", "https://www.$host", "https://x.y.$host")) {
            assertTrue("$store: $origin", rules.any { ruleMatches(it, origin) })
        }
        assertTrue(rules.none { ruleMatches(it, "https://evil.com") })
    }
}
