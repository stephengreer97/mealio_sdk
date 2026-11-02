plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
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

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
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

afterEvaluate {
    publishing {
        publications {
            create<MavenPublication>("release") {
                from(components["release"])
                groupId = "co.mealio"
                artifactId = "mealio-sdk"
                version = "0.2.0"
            }
        }
    }
}
