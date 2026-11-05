import com.vanniktech.maven.publish.AndroidSingleVariantLibrary
import com.vanniktech.maven.publish.SonatypeHost

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("com.vanniktech.maven.publish")
}

android {
    namespace = "co.mealio.sdk"
    compileSdk = 34

    defaultConfig {
        minSdk = 24
        // Shipped inside the AAR and applied to the partner app's R8 run.
        consumerProguardFiles("consumer-rules.pro")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    // WebViewCompat.addDocumentStartJavaScript + WebViewFeature.
    // VERIFY: DOCUMENT_START_SCRIPT is public API in webkit 1.10.0 (it was
    // restricted in early 1.x releases).
    implementation("androidx.webkit:webkit:1.10.0")
    // Ed25519. The platform only has it from API 33.
    // VERIFY: D8/R8 accept the multi-release bcprov jar without packaging excludes.
    implementation("org.bouncycastle:bcprov-jdk18on:1.77")

    testImplementation("junit:junit:4.13.2")
    // android.jar's org.json is a stub that throws in JVM unit tests. The real
    // implementation on the test classpath takes its place.
    // VERIFY: AGP puts this ahead of the android.jar stub on the unit-test classpath.
    testImplementation("org.json:json:20231013")
}

// Maven Central: co.mealio:mealio-sdk. Signed only when a key is present (the
// release workflow passes one), so CI can still publishToMavenLocal.
mavenPublishing {
    configure(AndroidSingleVariantLibrary(variant = "release", sourcesJar = true, publishJavadocJar = true))
    publishToMavenCentral(SonatypeHost.CENTRAL_PORTAL, automaticRelease = true)
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()
    coordinates("co.mealio", "mealio-sdk", providers.gradleProperty("mealioVersion").get())
    pom {
        name.set("Mealio Cart SDK")
        description.set("Adds a recipe's ingredients to the user's own grocery store cart, driven by signed instructions from Mealio.")
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
