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

dependencies {
    implementation("androidx.work:work-runtime-ktx:2.9.0")
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

        // arm64-v8a = real devices; x86_64 = emulator only.
        // armeabi-v7a excluded — saves ~20MB in APK (32-bit ARM is <2% of active devices).
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
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

// Chaquopy: embed CPython and the pure-Python pipeline shared with iOS /
// macOS sidecar. Android (unlike iOS) ships _socket + _ssl, so aiohttp
// and edge_tts run unmodified — no Swift-side network bridge needed.
chaquopy {
    defaultConfig {
        version = "3.13"
        // Chaquopy needs a Python 3.13 on the build host to resolve pip
        // dependencies. Read from gradle.properties so each contributor
        // can point at their own install (mise, pyenv, system, …).
        // Default: the mise-managed 3.13 path on macOS.
        val buildPythonPath = project.findProperty("chaquopy.buildPython")
            ?.toString()
            ?: "${System.getProperty("user.home")}/.local/share/mise/installs/python/3.13.13/bin/python3.13"
        buildPython(buildPythonPath)
        pip {
            install("edge-tts")
            install("aiohttp")
            install("pypdf")
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
