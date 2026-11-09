import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "co.mealio.sdk.compose"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        // Matches Kotlin 1.9.22 (root build.gradle.kts).
        kotlinCompilerExtensionVersion = "1.5.10"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        // Interface defaults (Host.pagesLost, HttpTransport.get) as real JVM
        // default methods, so a Java class implementing Host needs only the
        // abstract ones. "-compatibility" keeps the DefaultImpls that Kotlin
        // code built against 0.5 calls.
        freeCompilerArgs += "-Xjvm-default=all-compatibility"
    }

    testOptions {
        // The flow model is plain Kotlin; Android calls it may reach return defaults.
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    api(project(":mealio-sdk"))

    val bom = platform("androidx.compose:compose-bom:2024.02.00")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    // android.jar's org.json is a stub; the SDK parses with the real one in tests.
    testImplementation("org.json:json:20231013")
    // Signs test envelopes with the shared TEST key.
    testImplementation("org.bouncycastle:bcprov-jdk18on:1.77")
}

// Maven Central: co.mealio:mealio-sdk-compose. Signed only when a key is present (the
// release workflow passes one), so CI can still publishToMavenLocal.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL, automaticRelease = true)
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
    coordinates("co.mealio", "mealio-sdk-compose", providers.gradleProperty("mealioVersion").get())
    pom {
        name.set("Mealio Cart SDK for Compose")
        description.set("The drop-in Jetpack Compose cart sheet and button for the Mealio Cart SDK.")
        inceptionYear.set("2026")
        url.set("https://developers.mealio.co")
        licenses {
            license {
                name.set("Mealio Cart SDK License")
                url.set("https://github.com/stephengreer97/mealio_sdk/blob/main/LICENSE")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("mealio")
                name.set("Mealio")
                email.set("contact@mealio.co")
            }
        }
        scm {
            url.set("https://github.com/stephengreer97/mealio_sdk")
            connection.set("scm:git:https://github.com/stephengreer97/mealio_sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/stephengreer97/mealio_sdk.git")
        }
    }
}
