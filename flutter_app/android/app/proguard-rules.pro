-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

-dontwarn io.flutter.embedding.**

# Rust invokes this adapter by its stable JNI name and signature.
-keepclassmembers class com.pietrocode.epubtomp3.flutter_app.MainActivity {
    public boolean synthesizeNativeSpeech(java.lang.String, java.lang.String, java.lang.String, java.lang.String, long);
    public boolean onNativeAudioChunk(java.lang.String, int, int, java.lang.String);
    native <methods>;
}

# The minified androidTest APK (R8 proof of the ML Kit OCR) references compile-only annotations.
-dontwarn com.google.errorprone.annotations.**

# ML Kit instantiates the Firebase registrars named in manifest metadata by reflection.
-keep,allowoptimization class com.google.mlkit.** implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}
