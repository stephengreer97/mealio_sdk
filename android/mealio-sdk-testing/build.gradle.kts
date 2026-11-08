import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "co.mealio.sdk.testing"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
        freeCompilerArgs += "-Xjvm-default=all-compatibility"
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

dependencies {
    api(project(":mealio-sdk"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    // Signs fake envelopes with the shared TEST key.
    implementation("org.bouncycastle:bcprov-jdk18on:1.77")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.7.3")
    // android.jar's org.json is a stub that throws in JVM unit tests.
    testImplementation("org.json:json:20231013")
}

// Maven Central: co.mealio:mealio-sdk-testing. Signed only when a key is present (the
// release workflow passes one), so CI can still publishToMavenLocal.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL, automaticRelease = true)
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
    coordinates("co.mealio", "mealio-sdk-testing", providers.gradleProperty("mealioVersion").get())
    pom {
        name.set("Mealio Cart SDK testing kit")
        description.set("A scripted fake Mealio for JVM and Robolectric tests of apps using the Mealio Cart SDK. For testImplementation only.")
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
