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

    // ── 0.6 round 5: dormant at document start, armed before each Mealio script ──

    @Test
    fun theArmingCopyMatchesTheReferenceByteForByte() {
        assertEquals(readResource("guard-arm-expected.js"), GUARD_ARM_SCRIPT)
        assertEquals(GUARD_SCRIPT + "\n" + GUARD_ARM, GUARD_ARM_SCRIPT)
    }

    @Test
    fun theDocumentStartCopyIsTheDormantOne() {
        val (script, _) = documentStartScripts(LISTENER_BOOTSTRAP_SCRIPT)[1]
        assertEquals(GUARD_SCRIPT, script)
        assertTrue("does not arm itself", !script.contains(GUARD_ARM))
        // Its first act: leave a cross-origin frame alone.
        val first = script.lines().drop(1).map { it.trim() }.first { it.isNotEmpty() && !it.startsWith("//") }
        assertTrue(first, first.contains("window.top") && first.contains("return"))
    }

    @Test
    fun everyMealioScriptIsPrecededByTheArmingCopy(): Unit = kotlinx.coroutines.runBlocking {
        val guards = mutableListOf<String>()
        var login: LoginRequest? = null
        val host = object : Host by FakeHost() {
            override suspend fun runScript(store: String, guard: String, script: String, until: List<Matcher>, timeoutMs: Long): ScriptRun {
                guards.add(guard)
                return ScriptRun(listOf(org.json.JSONObject().put("type", "X")), timedOut = false)
            }
            override suspend fun showLogin(request: LoginRequest): LoginResult {
                login = request
                return LoginResult(LoginOutcome.SIGNED_IN, emptyList())
            }
        }
        val env = TestSigner.instructions(1, listOf(pageScript("s1", "X"), showLoginOp("l1", "https://www.heb.com/my-account/login")))
        Runner(host, Allowlist(), Vectors.keys).run(env, "job_test", 0)
        assertEquals(listOf(GUARD_ARM_SCRIPT), guards)
        assertEquals(GUARD_SCRIPT, login!!.guard)
        assertEquals(GUARD_ARM_SCRIPT, login!!.armGuard)
    }
}
