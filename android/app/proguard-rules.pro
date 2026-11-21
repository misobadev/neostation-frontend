# Flutter standard rules
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Prevent R8 from removing native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep the sqlite3 classes
-keep class org.sqlite.** { *; }
-keep class sqlite3.** { *; }

# For general plugins that might use reflection
-dontwarn io.flutter.plugins.**
-dontwarn com.neogamelab.neostation.**

# Fix for missing Play Core classes referenced by Flutter engine
-dontwarn com.google.android.play.core.**
