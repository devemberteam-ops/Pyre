import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config. The keystore itself and its passwords MUST NOT
// live in this repo — they're loaded from `android/key.properties` which is
// gitignored (and from CI secrets in production builds). See docs/RELEASE.md
// for one-time setup instructions.
//
// If the properties file is missing (e.g. a contributor build), we silently
// fall back to debug signing so `flutter run --release` still works locally.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasKeystore = keystorePropertiesFile.exists()
if (hasKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    // Code namespace — the Kotlin/Java package that R.java/BuildConfig
    // live under. Tied to the directory layout in src/main/kotlin/.
    // Leave alone unless you also move MainActivity.kt.
    namespace = "com.example.emberchat"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // PUBLIC application id — this is what Play Store / sideloaded
        // installers key off, and what survives in user telemetry forever.
        // Once shipped publicly this value is essentially permanent;
        // changing it means losing the install base on next update.
        //
        // TODO(before-first-release): pick a reverse-DNS prefix that
        // identifies the publisher. Examples:
        //   - `app.<name>`         (e.g. `app.ember`)
        //   - `<tld>.<name>.app`   (e.g. `xyz.ember.app`)
        //   - `io.github.<user>.<name>`  (if you ever make a repo)
        // The TLD doesn't have to resolve to a real website. Just pick
        // something unique enough that it won't collide with another
        // publisher's app on the Play Store.
        applicationId = "app.pyre.client"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Wave 1.1 "Pyre Dev" channel: when built with the PYRE_DEV env var
        // set, the app installs SIDE-BY-SIDE with production (distinct
        // applicationId suffix + label). With NO env var (production + CI),
        // this is inert — applicationId stays `app.pyre.client` and the label
        // stays "Pyre", byte-identical to before. Paired with the
        // `--dart-define=PYRE_DEV=true` that flips the Dart-side data dir.
        manifestPlaceholders["appLabel"] = "Pyre"
        if (System.getenv("PYRE_DEV") == "true") {
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "Pyre Dev"
        }
    }

    signingConfigs {
        if (hasKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Wave CY.18.253: minification DISABLED. R8 was obfuscating
            // Google ML Kit's reflection-based barcode classes (used by
            // mobile_scanner for the QR pairing scanner), causing a release-
            // only NPE ("invoke virtual method ... on a null object
            // reference") the instant the camera started. This app is AGPL
            // (source is public, so obfuscation protects nothing) and its
            // size is dominated by bundled image assets (R8 only shrinks the
            // small Java/Kotlin glue), so minify buys ~nothing here while
            // breaking the scanner. proguard-rules.pro still carries the
            // ML Kit keep rules in case minify is ever re-enabled.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (hasKeystore) {
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
