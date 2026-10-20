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

# WorkManager conversions use the same Rust-to-Kotlin speech callback.
-keepclassmembers class com.pietrocode.epubtomp3.flutter_app.BackgroundChapterWorker {
    public boolean synthesizeNativeSpeech(java.lang.String, java.lang.String, java.lang.String, java.lang.String, long);
    native <methods>;
}
