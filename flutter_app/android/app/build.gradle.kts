plugins {
    id("com.android.application")
    // AGP provides built-in Kotlin; apply Flutter after the Android plugin.
    id("dev.flutter.flutter-gradle-plugin")
}

dependencies {
    // On-device OCR for scanned PDF pages (bundled Latin model, no network).
    implementation("com.google.mlkit:text-recognition:16.0.1")
    // Built-in Kotlin needs the JVM test backend explicitly selected.
    testImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.4.0")
    androidTestImplementation("org.jetbrains.kotlin:kotlin-test-junit:2.4.0")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:core:1.6.1")
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

    // The instrumented OCR test runs against the minified release build: `./gradlew :app:connectedReleaseAndroidTest`.
    testBuildType = "release"
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
        // The launcher category of the main activity. The device-verification build replaces it
        // (below) so a test build never shows a second EpubToMp3 icon next to the user's app.
        manifestPlaceholders["launcherCategory"] = "android.intent.category.LAUNCHER"
    }

    buildTypes {
        getByName("debug") {
            // Keep device verification separate when the installed app has another signer.
            if (providers.environmentVariable("EPUB2MP3_ANDROID_VERIFICATION").orNull == "1") {
                applicationIdSuffix = ".verification"
                // No launcher icon: the farm starts it through the MONKEY category (`monkey -p`) or `am start`.
                manifestPlaceholders["launcherCategory"] = "android.intent.category.MONKEY"
            }
        }
        release {
            // Release Desktop signs the unsigned APK separately with the pinned key.
            if (providers.environmentVariable("EPUBTOPMP3_ANDROID_OFFICIAL_RELEASE").orNull != "1") {
                signingConfig = signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
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
