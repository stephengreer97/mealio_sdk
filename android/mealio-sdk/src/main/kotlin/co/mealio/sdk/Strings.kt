package co.mealio.sdk

// Every word the drop-in shows, in one table. Partners change or translate any
// of them. {store}-style placeholders are filled in at runtime. A key ending
// _one or _other is the singular or plural of the same message.
//
// protocol/strings.json is the source. Every SDK carries the same table, and
// StringsTest checks that this one still matches. Port of
// packages/core/src/strings.ts.

val DEFAULT_STRINGS: Map<String, String> = linkedMapOf(
    "addToCart" to "Add to my grocery cart",
    "addToCartShort" to "Add to cart",
    "close" to "Close",
    "somethingWrong" to "Something went wrong",
    "somethingWrongSentence" to "Something went wrong.",
    "couldNotAdd" to "Could not add to your cart.",
    "signInClosed" to "Sign-in was closed before it finished.",
    "tryAgain" to "Try again",
    "yourStore" to "your store",
    "meals" to "{count} meals",
    "titleInCartPlain" to "In your cart",
    "titleInCart" to "In your {store} cart",
    "titleLoadingPlain" to "Getting your cart ready",
    "titleLoading" to "Getting your {store} cart ready",
    "titleStores" to "Choose your store",
    "titleLocation" to "Find your {store}",
    "titleList" to "Your {store} list",
    "titleSettings" to "Your grocery store",
    "loginNote" to "Sign in on {store}'s own page. Mealio never sees your password.",
    "loadingNote" to "Checking prices and stock at {store}.",
    "stepSignIn" to "Checking your {store} sign-in",
    "stepFinding_one" to "Finding your {count} ingredient",
    "stepFinding_other" to "Finding your {count} ingredients",
    "change" to "Change",
    "choose" to "Choose",
    "done" to "Done",
    "current" to "Current",
    "selectedCount" to "{count} of {total} selected",
    "rememberNote" to "Pick a product for each item and Mealio will remember your preferences.",
    "pendingOptions_one" to "1 checked item needs an option chosen before adding.",
    "pendingOptions_other" to "{count} checked items need an option chosen before adding.",
    "total" to "Total",
    "estimatedTotal" to "Estimated total",
    "pricesAtCheckout" to "Prices at checkout",
    "aboutPrice" to "about {price}",
    "addItems_one" to "Add 1 item to {store}",
    "addItems_other" to "Add {count} items to {store}",
    "selectItems" to "Select items to add",
    "notFoundAt" to "Not found at {store}",
    "nothingFound" to "Nothing found for \"{query}\".",
    "searchFailed" to "Search failed. Try again.",
    "searchPlaceholder" to "Search {store} for something else",
    "search" to "Search",
    "yourUsual" to "Your usual",
    "notAddingThisTime" to "Not adding this time",
    "usualOutOfStock" to "Your usual is out of stock",
    "options_one" to "1 option",
    "options_other" to "{count} options",
    "chooseProduct" to "Choose a product",
    "chooseOne" to "Choose one: {options}",
    "weight" to "Weight",
    "quantity" to "Quantity",
    "usualNotAvailableNamed" to "Your usual, {name}, is not available today. Pick another this time. It stays your usual.",
    "usualNotAvailable" to "Your usual is not available today. Pick another this time. It stays your usual.",
    "usualOutNamed" to "Your usual, {name}, is out of stock today. Pick another this time. It stays your usual.",
    "usualOut" to "Your usual is out of stock today. Pick another this time. It stays your usual.",
    "outOfStock" to "Out of stock",
    "crowdFavorite" to "Crowd favorite",
    "itemsAdded_one" to "1 item added",
    "itemsAdded_other" to "{count} items added",
    "nothingAdded" to "Nothing was added",
    "cartUnchanged" to "Your cart did not change.",
    "leftOut" to "Left out this time",
    "neededOption" to "Needed an option chosen",
    "uncheckedThisTime" to "Unchecked this time",
    "notChosen" to "Not chosen",
    "reasonNotConfirmed" to "not confirmed in your cart",
    "reasonWeight" to "sold by weight, which this store cannot take here",
    "reasonOutOfStock" to "out of stock",
    "reasonNoAnswer" to "the store did not answer",
    "reasonRefused" to "the store refused it",
    "pricePerLb" to "{price}/lb est.",
    "priceEstimate" to "{price} est.",
    "forRecipes" to "For {recipes}",
    "and" to "and",
    "or" to "or",
    "backToList" to "Back to your list",
    "backToStores" to "Back to your stores",
    "differentStore" to "Choose a different store",
    "couldNotLoadStores" to "Could not load stores. Close and try again.",
    "couldNotLoadYourStores" to "Could not load your stores.",
    "couldNotLookUp" to "Could not look up stores. Try again.",
    "couldNotSaveStore" to "Could not save that store. Try again.",
    "zipPrompt" to "Enter your zip code to see {store} stores near you.",
    "zipCode" to "Zip code",
    "findStores" to "Find stores",
    "noStoresNear" to "No {store} stores near {zip}. Try another zip code.",
    "a11yLeaveOut" to "Leave out {item}",
    "a11yAdd" to "Add {item}",
    "a11yLess" to "Less {item}",
    "a11yMore" to "More {item}",
    "a11yChangeLocation" to "Store location: {name}. Change location",
    "a11yChangeStore" to "Store: {store}. Change store",
)

private val PLACEHOLDER = Regex("\\{(\\w+)\\}")

/** Fill {placeholders}. One with no value stays as written, so a typo shows. */
fun fillText(template: String, vars: Map<String, Any> = emptyMap()): String =
    PLACEHOLDER.replace(template) { m -> vars[m.groupValues[1]]?.toString() ?: m.value }

/**
 * The words in force: [DEFAULT_STRINGS] with the partner's overrides laid over
 * them. A key the table does not have reads as the key itself.
 */
open class TextTools(overrides: Map<String, String> = emptyMap()) {
    private val table: Map<String, String> = DEFAULT_STRINGS + overrides

    /** The text for a key, filled in. */
    fun tr(key: String, vararg vars: Pair<String, Any>): String =
        fillText(table[key] ?: key, vars.toMap())

    /** `base_one` for 1, `base_other` otherwise. `count` is filled in for you. */
    fun plural(base: String, count: Int, vararg vars: Pair<String, Any>): String {
        val key = base + if (count == 1) "_one" else "_other"
        return fillText(table[key] ?: key, mapOf<String, Any>("count" to count) + vars)
    }
}
