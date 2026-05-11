plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Chaquopy embeds CPython 3.13 + python_app/src into the APK. Run
    // `mise run android:bootstrap-python` first to populate
    // src/main/python/python_app/ before any build.
    id("com.chaquo.python")
}

android {
    namespace = "com.pietrocode.epubtomp3.flutter_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

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
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Chaquopy ships CPython + the chosen wheels for every ABI we list
        // here. Keep this in sync with the iOS Python.xcframework version
        // (3.13) so both clients run the same interpreter family.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// Chaquopy: embed CPython and the pure-Python pipeline shared with iOS /
// macOS sidecar. Android (unlike iOS) ships _socket + _ssl, so aiohttp
// and edge_tts run unmodified — no Swift-side network bridge needed.
chaquopy {
    defaultConfig {
        version = "3.13"
        pip {
            install("edge-tts")
            install("aiohttp")
        }
    }
    sourceSets {
        getByName("main") {
            srcDir("src/main/python")
        }
    }
}

flutter {
    source = "../.."
}
