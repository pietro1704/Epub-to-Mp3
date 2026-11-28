# AndroidJUnitRunner calls the target APK's shared AndroidX tracing dependency at startup.
-keep class androidx.tracing.Trace { *; }

# The separately compiled test APK invokes this Kotlin object across the APK boundary.
-keep,allowoptimization class com.pietrocode.epubtomp3.flutter_app.PdfPageOcr {
    public static final com.pietrocode.epubtomp3.flutter_app.PdfPageOcr INSTANCE;
    public java.lang.String recognize(java.lang.String, int);
}
