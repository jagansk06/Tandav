import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing.
//
// Loaded from android/key.properties, which is gitignored and points at a
// keystore kept OUTSIDE this repository (D:\Projects\tandav-signing\). Two
// reasons this matters more than usual for Tandav:
//
//  1. Google Drive sync will not work without it. The Android OAuth client is
//     bound to the release keystore's SHA-1 fingerprint, so a differently
//     signed build cannot sign in at all.
//  2. Tandav is sold as a direct APK with no store update channel, and its
//     database is LOCAL-ONLY. If this key is lost, customers can never install
//     an update over their existing app — and uninstalling to reinstall wipes
//     the only copy of their data.
//
// If key.properties or the keystore is absent the build deliberately falls back
// to debug signing rather than failing, so a fresh clone can still compile and
// run. That fallback produces an APK that CANNOT sync, which is why the warning
// below is printed loudly instead of passing silently.
// ---------------------------------------------------------------------------
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
var hasReleaseSigning = false

if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
    val storeFilePath = keystoreProperties["storeFile"] as String?
    // Check the keystore is actually there. Without this the build configures
    // fine and then fails much later, during signing, with a message that does
    // not mention key.properties at all.
    if (storeFilePath != null && file(storeFilePath).exists()) {
        hasReleaseSigning = true
    } else {
        logger.warn("WARNING: key.properties exists but storeFile '$storeFilePath' " +
                    "was not found. Falling back to DEBUG signing.")
    }
} else {
    logger.warn("WARNING: android/key.properties not found. Release builds will be " +
                "signed with DEBUG keys and will NOT be able to sign in to Google Drive.")
}

android {
    namespace = "com.tandav.tandav_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tandav.tandav_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                // Generated as PKCS12 (keytool's modern default). Stated
                // explicitly so the build does not depend on AGP guessing.
                (keystoreProperties["storeType"] as String?)?.let { storeType = it }
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
