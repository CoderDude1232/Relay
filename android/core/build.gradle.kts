plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.relaymsg.core"
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
    // RelayCore equivalent: the shared envelope pipeline, content padding,
    // account/session orchestration.
    implementation(libs.kotlinx.coroutines.android)
    api(project(":proto"))
    implementation(project(":crypto"))
    implementation(project(":storage"))
    implementation(project(":net"))

    testImplementation(libs.junit)
    testImplementation(libs.gson)
    testImplementation(libs.kotlinx.coroutines.test)
}
