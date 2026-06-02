# Pyre ProGuard / R8 rules.
#
# We start from the default proguard-android-optimize.txt config; this
# file adds keep rules for plugins that use reflection or JNI hooks that
# R8 can't statically discover.

# --- Flutter ---
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# --- webview_flutter (Android) ---
# The WebView plugin uses reflection for JS channels.
-keep class io.flutter.plugins.webviewflutter.** { *; }

# --- flutter_secure_storage ---
# AndroidX Security (EncryptedSharedPreferences) needs Tink kept.
-keep class com.google.crypto.tink.** { *; }
-keep class androidx.security.crypto.** { *; }
-dontwarn com.google.crypto.tink.**

# --- url_launcher ---
-keep class io.flutter.plugins.urllauncher.** { *; }

# --- file_picker ---
-keep class com.mr.flutter.plugin.filepicker.** { *; }

# --- shared_preferences ---
-keep class io.flutter.plugins.sharedpreferences.** { *; }

# --- path_provider ---
-keep class io.flutter.plugins.pathprovider.** { *; }

# Keep model classes that we serialize via reflection (none today, but
# leave the rule scaffolded — toJson/fromJson are explicit dart so this
# is currently a no-op, here for forward compatibility).
-keep class com.example.emberchat.models.** { *; }

# Don't strip kotlin coroutines stack frames (helps real crash reports).
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- mobile_scanner / Google ML Kit barcode (Wave CY.18.253) ---
# The QR pairing scanner (mobile_scanner) reads codes via Google ML Kit,
# which resolves classes by reflection. With minify ON, R8 stripped/
# obfuscated them, producing a release-only NPE at camera start:
#   "Attempt to invoke virtual method '...' on a null object reference".
# Minify is currently DISABLED in build.gradle.kts, so these are belt-and-
# suspenders — keep them so re-enabling minify later stays safe.
-keep class com.google.mlkit.** { *; }
-keep interface com.google.mlkit.** { *; }
-dontwarn com.google.mlkit.**
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google.android.gms.vision.** { *; }
-dontwarn com.google.android.gms.**
-keep class dev.steenbakker.mobile_scanner.** { *; }
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**
