// Versions in one place. Kotlin 1.9.22 pairs with Compose compiler 1.5.10.
plugins {
    id("com.android.library") version "8.3.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    // 0.28.0: the first with Sonatype Central Portal publishing, built for Gradle 8.7's Kotlin.
    id("com.vanniktech.maven.publish") version "0.28.0" apply false
}
