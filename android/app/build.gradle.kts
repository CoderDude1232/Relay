plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// Firebase is configured by a google-services.json obtained from the Firebase
// console. Applying the plugin unconditionally would fail the build for anyone
// who hasn't added that file yet, so it is applied only when present: the app
// builds and runs without push until the file is dropped in, then lights up.
val googleServicesConfig = file("google-services.json")
if (googleServicesConfig.exists()) {
    apply(plugin = "com.google.gms.google-services")
} else {
    logger.lifecycle(
        "Relay: app/google-services.json absent - building WITHOUT FCM push. " +
            "Add it from the Firebase console to enable background delivery.",
    )
}

android {
    namespace = "app.relaymsg"
    compileSdk {
        version = release(37)
    }

    defaultConfig {
        applicationId = "app.relaymsg"
        minSdk = 26
        targetSdk = 37
        versionCode = 1
        versionName = "1.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        debug {
            ndk {
                // libsignal_jni.so is ~140 MB per ABI, so every extra ABI is another
                // ~140 MB of debug APK. This Mac is Apple Silicon and its emulator
                // images are arm64, same as the owner's phone, so debug ships one ABI.
                // Add "x86_64" here if you ever run an Intel host or x86_64 system
                // image (the symptom is INSTALL_FAILED_NO_MATCHING_ABIS).
                // Release is unfiltered and keeps all four.
                abiFilters += listOf("arm64-v8a")
            }
        }
        release {
            optimization {
                enable = false
            }
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by libsignal-android (it uses java.time / java.util.stream APIs
        // above our minSdk of 26).
        isCoreLibraryDesugaringEnabled = true
    }
    buildFeatures {
        compose = true
    }
    packaging {
        jniLibs {
            // libsignal-android ships a ~115 MB-per-ABI test-only native library
            // next to the real one. Without this the APK is several hundred MB.
            excludes += "**/libsignal_jni_testing.so"
        }
        resources {
            // libsignal-android depends on the JVM libsignal-client, which
            // carries desktop natives as ordinary jar resources: macOS dylibs
            // and Windows DLLs, ~178 MB of them. They sit at the APK root and
            // can never be loaded on Android. The real Android library is a
            // jniLib under lib/<abi>/ and is not matched by these patterns.
            excludes += listOf(
                "libsignal_jni*.dylib",
                "libsignal_jni*.dll",
                "signal_jni*.dll",
                // The Linux desktop builds, which carry an arch suffix the
                // Android library does not.
                "libsignal_jni_amd64.so",
                "libsignal_jni_aarch64.so",
                "libsignal_jni_testing_amd64.so",
                "libsignal_jni_testing_aarch64.so",
            )
        }
    }
}

dependencies {
    coreLibraryDesugaring(libs.desugar.jdk.libs)
    implementation(project(":core"))
    implementation(project(":crypto"))
    implementation(project(":storage"))
    implementation(project(":net"))
    implementation(project(":proto"))

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.material.icons)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.webrtc)
    implementation(libs.zxing.core)
    implementation(libs.androidx.camera.core)
    implementation(libs.androidx.camera.camera2)
    implementation(libs.androidx.camera.lifecycle)
    implementation(libs.androidx.camera.view)
    implementation(libs.androidx.browser)
    implementation(libs.androidx.biometric)
    implementation(platform(libs.firebase.bom))
    implementation(libs.firebase.messaging)
    implementation(libs.kotlinx.coroutines.play.services)
    testImplementation(libs.junit)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(libs.androidx.junit)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
