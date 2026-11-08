pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "mealio-android"

// The core SDK has no Compose dependency. The drop-in sheet lives in its own
// optional module so apps that do not use Compose never pull it in.
include(":mealio-sdk")
include(":mealio-sdk-compose")
// The test kit (FakeMealio), its own artifact so it is only ever a
// testImplementation dependency and never ships in a release app.
include(":mealio-sdk-testing")
