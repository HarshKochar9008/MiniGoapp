import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

// Release signing config is read from android/key.properties (git-ignored).
// Falls back to debug signing when the file is absent (fresh checkouts / CI).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    // Must match package_name in android/app/google-services.json (Firebase Android app).
    namespace = "com.Zen.app"
    // Pinned to satisfy plugin requirements (mobile_scanner, androidx.core:core 1.18.0
    // both require compileSdk 36; multiple firebase/flutter plugins require NDK 27).
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.Zen.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // mobile_scanner requires API 23+. Android 6.0 Marshmallow (2015) is the floor;
        // < 0.1% of active Android devices are below this.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real release keystore when key.properties is present; otherwise
            // fall back to debug signing so plain checkouts still build.
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            // Strip x86_64 from release only — that ABI is emulators only; all
            // production Android phones are ARM. Debug keeps every ABI so the
            // app still runs on x86_64 emulators.
            // Gradle forbids ndk.abiFilters when ABI splits are active, so skip
            // it for `flutter build apk --split-per-abi` (-Psplit-per-abi).
            if (!project.hasProperty("split-per-abi")) {
                ndk {
                    abiFilters += listOf("arm64-v8a", "armeabi-v7a")
                }
            }
        }
        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
