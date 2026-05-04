# ── Flutter ────────────────────────────────────────────────────────────────────
# Flutter Gradle plugin injects its own rules; these cover the method-channel
# bridge and embedding layer that R8 would otherwise strip.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ── Kotlin / Coroutines ────────────────────────────────────────────────────────
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.coroutines.**

# ── Reflection metadata ────────────────────────────────────────────────────────
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# ── OkHttp / OkIO (Supabase networking layer) ──────────────────────────────────
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.internal.** { *; }

# ── Firebase (Firebase SDKs bundle their own rules; these are a safety net) ────
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-dontwarn com.google.android.gms.**

# ── CameraX / MLKit (mobile_scanner) ──────────────────────────────────────────
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**
-dontwarn com.google.mlkit.**
