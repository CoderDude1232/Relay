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
    testOptions {
        unitTests.isIncludeAndroidResources = true
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
    testImplementation(libs.gson)
    // org.json ships as a stub in android.jar; the real implementation lets the
    // request layer be unit-tested on the JVM. (Robolectric would also work, but
    // 4.17 cannot run on this toolchain's JDK 25.)
    testImplementation(libs.json)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
}
