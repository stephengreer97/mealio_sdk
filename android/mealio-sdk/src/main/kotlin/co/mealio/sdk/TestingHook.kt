package co.mealio.sdk

/**
 * The seam co.mealio:mealio-sdk-testing plugs into. Not for apps: the kit that
 * uses it is a separate artifact, added with `testImplementation`, so the fake
 * Mealio and its test key never ship in a release build.
 */
@RequiresOptIn(
    message = "For co.mealio:mealio-sdk-testing only. Use FakeMealio from that artifact.",
    level = RequiresOptIn.Level.ERROR,
)
@Retention(AnnotationRetention.BINARY)
@Target(AnnotationTarget.CLASS, AnnotationTarget.FUNCTION)
annotation class MealioTestingHook

/** What MealioCart.install needs from a test: the store sign-out epoch, in memory. */
@MealioTestingHook
interface TestSessions {
    fun epoch(): Int
    fun bumpEpoch(): Int
}

@MealioTestingHook
object MealioTesting {
    /**
     * Make MealioCart use `host` and the client `makeClient` builds, as
     * configure() would, with store sign-outs going to `sessions`.
     */
    fun install(host: Host, sessions: TestSessions, makeClient: (JobQueue) -> MealioClient): MealioClient =
        MealioCart.install(host, object : SessionStore {
            override fun epoch(): Int = sessions.epoch()
            override fun bumpEpoch(): Int = sessions.bumpEpoch()
            override suspend fun clearStore(hosts: StoreHosts) = Unit
            override suspend fun clearAll() = Unit
        }, release = {}, makeClient = makeClient)

    /** Undo [install]: MealioCart is unconfigured again and forgets the user. */
    fun uninstall() = MealioCart.uninstall()
}
