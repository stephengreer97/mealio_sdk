package co.mealio.sdk.testing

import co.mealio.sdk.CancelReason
import co.mealio.sdk.CancelToken
import co.mealio.sdk.KEYS
import co.mealio.sdk.LoginOutcome
import co.mealio.sdk.MealioCart
import co.mealio.sdk.MealioException
import co.mealio.sdk.Product
import co.mealio.sdk.Recipe
import co.mealio.sdk.RecipeIngredient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// The testing kit's own tests, written the way a partner's custom-screen
// tests would be: the real client and CartSession on the fake.
@OptIn(ExperimentalCoroutinesApi::class)
class FakeMealioTest {
    @After fun tearDown() {
        FakeMealio.uninstall()
        Dispatchers.resetMain()
    }

    private val milk = Product("m1", "Milk", unitPrice = 3.0)
    private val oat = Product("m2", "Oat milk", unitPrice = 4.5)
    private val salt = Product("s1", "Salt", unitPrice = 1.0)
    private val bread = Product("b1", "Bread")
    private val recipe = Recipe("r", listOf(RecipeIngredient("milk"), RecipeIngredient("salt")))

    private fun script() = FakeScript(items = listOf(
        FakeItem("milk", listOf(milk, oat), remembered = "m1"),
        FakeItem("salt", listOf(salt), remembered = "s1", startUnchecked = true),
    ))

    @Test
    fun theTestKeyIsNeverTrustedByDefault() {
        assertFalse(KEYS.containsKey("ktest"))
        assertEquals(setOf("ktest"), FakeMealio().config().keys.keys)
    }

    @Test
    fun rememberedPicksAndStartUncheckedItems() = runTest {
        val fake = FakeMealio(script())
        val cart = fake.client().prepareCart("heb", recipe)
        assertEquals("m1", cart.selectedId("milk"))
        assertNull("startUnchecked starts unticked", cart.selectedId("salt"))
        assertFalse(cart.isSelected("salt"))
        assertEquals(listOf(FakeKind.PREPARE), fake.requests.map { it.kind })
        assertEquals(listOf("open https://www.heb.com/"), fake.hostCalls)
        assertEquals(3.0, cart.estimate().total!!, 0.0)
    }

    @Test
    fun theTotalIsNullWhenAnySelectedItemHasNoPrice() = runTest {
        val fake = FakeMealio(FakeScript(items = listOf(FakeItem("milk", listOf(milk), "m1"), FakeItem("bread", listOf(bread), "b1"))))
        val cart = fake.client().prepareCart("heb", recipe)
        val e = cart.estimate()
        assertNull(e.total)
        assertEquals(1, e.unpriced)
        cart.deselect("bread")
        assertEquals(3.0, cart.estimate().total!!, 0.0)
    }

    @Test
    fun searchAddAndAProductTheCartWasNotOfferedFails() = runTest {
        val fake = FakeMealio(script().apply { search = mapOf("goat milk" to listOf(Product("g1", "Goat milk", unitPrice = 6.0))) })
        val client = fake.client()
        val cart = client.prepareCart("heb", recipe)
        assertEquals(listOf("g1"), cart.search("milk", "Goat Milk").map { it.id })
        cart.select("milk", "g1")
        cart.setQuantity("milk", 2)
        val r = cart.addToCart()
        assertEquals(listOf("g1"), r.added.map { it.productId })
        assertEquals(12.0, cart.addedTotal(r).total!!, 0.0)
        // The server knows a searched product only on the cart it was found on.
        val other = client.prepareCart("heb", recipe)
        val r2 = client.addToCart(other.cartId, listOf(co.mealio.sdk.Selection("milk", "g1", 1)))
        assertEquals("not_offered", r2.failed.single().reason)
    }

    @Test
    fun restorePicksSearchesAgainForASearchedProduct() = runTest {
        val goat = Product("g1", "Goat milk", unitPrice = 6.0)
        val fake = FakeMealio(script().apply { search = mapOf("goat milk" to listOf(goat)); addFail = FakeError("store_unavailable") })
        val client = fake.client()
        val old = client.prepareCart("heb", recipe)
        old.search("milk", "goat milk")
        old.select("milk", "g1")
        val failed = runCatching { old.addToCart() }.exceptionOrNull() as MealioException
        assertEquals("store_unavailable", failed.code)
        fake.script.addFail = null
        val fresh = client.prepareCart("heb", recipe)
        fresh.restorePicks(old)
        assertEquals("g1", fresh.selectedId("milk"))
        assertEquals(listOf(FakeKind.PREPARE, FakeKind.SEARCH, FakeKind.ADD, FakeKind.PREPARE, FakeKind.SEARCH), fake.requests.map { it.kind })
        assertEquals(listOf("g1"), fresh.addToCart().added.map { it.productId })
        // Gone from the store this time: the item keeps the new cart's own pick.
        fake.script.search = emptyMap()
        val third = client.prepareCart("heb", recipe)
        third.restorePicks(old)
        assertEquals("m1", third.selectedId("milk"))
    }

    @Test
    fun signInErrorsAndHeldRequests() = runTest {
        val fake = FakeMealio(script().apply { signIn = LoginOutcome.CANCELLED })
        val client = fake.client()
        assertEquals("login_cancelled", (runCatching { client.prepareCart("heb", recipe) }.exceptionOrNull() as MealioException).code)
        assertTrue("login" in fake.hostCalls)
        fake.script.signIn = LoginOutcome.SIGNED_IN
        client.prepareCart("heb", recipe)
        fake.script.errors = mapOf(FakeKind.PREPARE to FakeError("store_unavailable", "Down", status = 503))
        assertEquals("store_unavailable", (runCatching { client.prepareCart("heb", recipe) }.exceptionOrNull() as MealioException).code)
        fake.script.errors = mapOf(FakeKind.SESSION to FakeError("nope", "partner server down"))
        val fresh = fake.client()
        val e = runCatching { fresh.prepareCart("heb", recipe) }.exceptionOrNull() as MealioException
        assertEquals("session_failed" to "partner server down", e.code to e.message)
        // A held prepare can be cancelled, and says why.
        fake.script.errors = emptyMap()
        val release = fake.hold(FakeKind.PREPARE)
        val c = CancelToken()
        val p = async { runCatching { client.prepareCart("heb", listOf(recipe), null, c) }.exceptionOrNull() as? MealioException }
        runCurrent()
        c.cancel(CancelReason.CLOSED)
        release()
        assertEquals("cancelled" to CancelReason.CLOSED, p.await()!!.let { it.code to it.reason })
    }

    @Test
    fun installedMealioCartFollowsAUserSwitch() = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        val fake = FakeMealio(script())
        fake.install()
        MealioCart.setUser("ana")
        assertEquals("ana", MealioCart.prepareCart("heb", recipe).let { MealioCart.user.value.id })
        // A prepare under way when the user changes ends as user_changed, so a custom screen can prepare again.
        val release = fake.hold(FakeKind.PREPARE)
        val p = async { runCatching { MealioCart.prepareCart("heb", listOf(recipe), null, CancelToken()) }.exceptionOrNull() as? MealioException }
        runCurrent()
        MealioCart.setUser("ben")
        release()
        assertEquals(CancelReason.USER_CHANGED, p.await()!!.reason)
        runCurrent()
        assertEquals("Ana was signed out of the stores", 1, fake.storeEpoch)
        assertEquals("milk", MealioCart.prepareCart("heb", recipe).items.first().key)
        MealioCart.signOutOfAllStores()
        assertEquals(2, fake.storeEpoch)
    }
}
