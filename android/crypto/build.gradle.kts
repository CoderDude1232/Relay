plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "app.relaymsg.crypto"
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
    // CryptoCore equivalent: libsignal (PQXDH, ratchet, sender keys, safety
    // numbers, sealed sender) + libsodium (ristretto255 for the discovery OPRF).
    api(libs.libsignal.android)
    implementation(libs.lazysodium.android) {
        // JNA must come from the .aar, which carries the Android native libraries.
        // lazysodium's POM pulls the plain .jar; having both puts every
        // com.sun.jna class on the classpath twice and dexing fails.
        exclude(group = "net.java.dev.jna", module = "jna")
    }
    implementation(libs.jna) { artifact { type = "aar" } }
    implementation(libs.kotlinx.coroutines.android)
    implementation(project(":proto"))

    testImplementation(libs.junit)
    testImplementation(libs.kotlinx.coroutines.test)
    androidTestImplementation(libs.androidx.junit)
}
