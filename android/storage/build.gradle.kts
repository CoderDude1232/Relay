plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.relaymsg.storage"
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
    // SecureStorage equivalent: SQLCipher DB whose master key is wrapped by an
    // Android Keystore key; identity private key + registration id live in the
    // Keystore only, never in the database.
    implementation(libs.sqlcipher.android)
    implementation(libs.androidx.sqlite)
    implementation(libs.kotlinx.coroutines.android)
    implementation(project(":crypto"))
    implementation(project(":proto"))

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    // SQLCipher and the Android Keystore are platform APIs with no JVM
    // implementation, so this module's tests must run on a device or emulator.
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
}
