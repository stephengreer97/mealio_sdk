package co.mealio.sdk

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 0.6 round 7, the in-page guard port: the shipped guard has the round 7 form, worker and XHR changes. */
class Round7GuardTest {
    @Test fun guardJudgesSubmitAfterThePageInShadowRootsWithoutASecondFormData() {
        assertTrue(GUARD_SCRIPT.contains("addEL(t, 'submit', onSubmit, false)"))
        assertTrue(GUARD_SCRIPT.contains("evPrevented"))
        assertTrue(GUARD_SCRIPT.contains("attachShadow"))
        assertFalse(GUARD_SCRIPT.contains("w.addEventListener('submit', function (e) {"))
        assertFalse(GUARD_SCRIPT.contains("new FD(form)"))
        assertTrue(GUARD_SCRIPT.contains("construct(W, args, NT)"))
        assertTrue(GUARD_SCRIPT.contains("if (sync) return go(null);"))
    }
}
