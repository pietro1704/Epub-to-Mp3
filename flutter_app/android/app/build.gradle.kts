plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.9.0")
    testImplementation(kotlin("test"))
}

android {
    namespace = "com.pietrocode.epubtomp3.flutter_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // converter-ffi artifacts are packaged under src/main/jniLibs/<ABI>/.
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
            assets.srcDirs("src/main/assets")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.pietrocode.epubtomp3.flutter_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The installed NDK rejects the Flutter plugin's unresolved platform 1 default.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    }

    buildTypes {
        getByName("debug") {
            // Keep device verification separate when the installed app has another signer.
            if (providers.environmentVariable("EPUB2MP3_ANDROID_VERIFICATION").orNull == "1") {
                applicationIdSuffix = ".verification"
            }
        }
        // Flutter supplies ABI filters per build type, overriding defaultConfig.
        // Match the packaged Rust runtime for every APK entry point.
        all {
            ndk {
                abiFilters.clear()
                abiFilters += listOf("arm64-v8a")
            }
        }
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

flutter {
    source = "../.."
}

// Generated native inputs are intentionally ignored by Git. Direct Flutter/Gradle
// builds must fail closed; the mise APK tasks build and validate them first.
val verifyEmbeddedTtsInputs by tasks.registering {
    doLast {
        val nativeLibrary = file("src/main/jniLibs/arm64-v8a/libconverter_ffi.so")
        val assets = file("src/main/assets/espeak-ng-data")
        val required = listOf(nativeLibrary) + listOf("phontab", "phondata", "phonindex", "lang/roa/pt").map { assets.resolve(it) }
        val missing = required.filter { !it.isFile || it.length() == 0L }
        if (missing.isNotEmpty()) {
            throw GradleException("Embedded Piper/JNI inputs are missing. Run mise run flutter:build-apk-debug (or flutter:build-apk) from the repository root. Missing: ${missing.joinToString()}")
        }
    }
}
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    dependsOn(verifyEmbeddedTtsInputs)
}
