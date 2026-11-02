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
}
