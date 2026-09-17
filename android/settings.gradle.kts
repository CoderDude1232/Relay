pluginManagement {
    repositories {
        google {
            content {
                includeGroupByRegex("com\\.android.*")
                includeGroupByRegex("com\\.google.*")
                includeGroupByRegex("androidx.*")
            }
        }
        mavenCentral()
        gradlePluginPortal()
    }
}
plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "1.0.0"
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // libsignal's Android/Java artifacts are NOT on Maven Central past 0.86.5.
        // Signal publishes them to their own bucket (see the vendored checkout's
        // java/build.gradle `publishing.repositories`). We need 0.97.4 to match iOS.
        maven {
            name = "signal"
            url = uri("https://storage.googleapis.com/build-artifacts.signal.org/libraries/maven")
            content { includeGroupByRegex("org\\.signal.*") }
        }
    }
}

rootProject.name = "Relay"

// Module layout mirrors the iOS packages:
//   :proto   <- proto/ codegen           (no iOS analogue; generated into RelayKit there)
//   :crypto  <- CryptoCore
//   :storage <- SecureStorage
//   :net     <- RelayKit
//   :core    <- RelayCore
//   :app     <- Relay/
include(":app")
include(":proto")
include(":crypto")
include(":storage")
include(":net")
include(":core")
