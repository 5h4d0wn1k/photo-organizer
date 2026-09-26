import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing material can come from two sources, in precedence order:
//  1. Environment variables (GitHub Actions secrets). Preferred for CI, because secrets
//     never touch the repository working tree.
//  2. A local `private-gallery-release.properties` file (git-ignored) for local release builds.
// Environment variables win so CI is authoritative when both are present.
val releaseSigningPropertiesFile = rootProject.file("private-gallery-release.properties")
val releaseSigningProperties = Properties()
if (releaseSigningPropertiesFile.exists()) {
    releaseSigningPropertiesFile.inputStream().use { releaseSigningProperties.load(it) }
}

fun signingValue(propertyName: String, envName: String): String? {
    val fromEnv = providers.environmentVariable(envName).orNull?.takeIf { it.isNotBlank() }
    if (fromEnv != null) {
        return fromEnv
    }
    return releaseSigningProperties.getProperty(propertyName)?.takeIf { it.isNotBlank() }
}

val storeFileValue = signingValue("storeFile", "ANDROID_KEYSTORE_FILE")
val storePasswordValue = signingValue("storePassword", "ANDROID_KEYSTORE_PASSWORD")
val keyAliasValue = signingValue("keyAlias", "ANDROID_KEY_ALIAS")
val keyPasswordValue = signingValue("keyPassword", "ANDROID_KEY_PASSWORD")

val hasReleaseSigning =
    listOf(storeFileValue, storePasswordValue, keyAliasValue, keyPasswordValue)
        .all { !it.isNullOrBlank() }

android {
    namespace = "com.privategallery.app"
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
        applicationId = "com.privategallery.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = rootProject.file(storeFileValue)
                storePassword = storePasswordValue
                keyAlias = keyAliasValue
                keyPassword = keyPasswordValue
                // Ship V1+V2+V3 so the APK installs on legacy sideload-capable Android
                // as well as modern devices. Without V1 some stock installers reject
                // the package outright ("App not installed").
                enableV1Signing = true
                enableV2Signing = true
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

flutter {
    source = "../.."
}
