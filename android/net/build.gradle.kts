plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.relaymsg.net"
    compileSdk {
        version = release(37)
    }
    defaultConfig {
        minSdk = 26
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by libsignal-android (it uses java.time / java.util.stream APIs
        // above our minSdk of 26).
        isCoreLibraryDesugaringEnabled = true
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)
    // RelayKit equivalent: REST + WebSocket client, Relay-Sig request signing,
    // prekey maintenance.
    implementation(libs.okhttp)
    implementation(libs.kotlinx.coroutines.android)
    api(project(":proto"))
    implementation(project(":crypto"))
    testImplementation(libs.okhttp.mockwebserver)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
