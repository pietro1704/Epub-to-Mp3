struct AndroidPlatformSpeech {
    vm: JavaVM,
    activity: GlobalRef,
    input_path: String,
}

fn android_controls() -> &'static std::sync::Mutex<HashMap<String, ConversionControl>> {
    static CONTROLS: std::sync::OnceLock<std::sync::Mutex<HashMap<String, ConversionControl>>> =
        std::sync::OnceLock::new();
    CONTROLS.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePrepareConversion(
    mut env: JNIEnv<'_>,
    _activity: JObject<'_>,
    request: JString<'_>,
) {
    if let Ok(request) = read_string(&mut env, request) {
        android_controls()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .entry(request)
            .or_default();
    }
}

#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeCancelConversion(
    mut env: JNIEnv<'_>,
    _activity: JObject<'_>,
    request: JString<'_>,
) {
    if let Ok(request) = read_string(&mut env, request) {
        if let Some(control) = android_controls()
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .get(&request)
            .cloned()
        {
            control.cancel();
        }
    }
}

struct BorrowedCancellation<'a>(&'a (dyn Fn() -> bool + Sync));

impl converter_core::platform_tts::PlatformTts for AndroidPlatformSpeech {
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        let mut env = self
            .vm
            .attach_current_thread()
            .map_err(|error| error.to_string())?;
        let text = JObject::from(env.new_string(text).map_err(|error| error.to_string())?);
        let language = JObject::from(
            env.new_string(language)
                .map_err(|error| error.to_string())?,
        );
        let output = JObject::from(
            env.new_string(output.to_string_lossy())
                .map_err(|error| error.to_string())?,
        );
        let input = JObject::from(
            env.new_string(&self.input_path)
                .map_err(|error| error.to_string())?,
        );
        let cancellation = BorrowedCancellation(cancelled);
        let result = env.call_method(
            self.activity.as_obj(),
            "synthesizeNativeSpeech",
            "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;J)Z",
            &[
                JValue::Object(&text),
                JValue::Object(&language),
                JValue::Object(&output),
                JValue::Object(&input),
                JValue::Long(&cancellation as *const BorrowedCancellation<'_> as jlong),
            ],
        );
        if env.exception_check().unwrap_or(false) {
            let exception = env
                .exception_occurred()
                .map_err(|error| error.to_string())?;
            env.exception_clear().map_err(|error| error.to_string())?;
            let message = env
                .call_method(exception, "toString", "()Ljava/lang/String;", &[])
                .and_then(|value| value.l())
                .ok()
                .and_then(|value| read_string(&mut env, JString::from(value)).ok())
                .unwrap_or_else(|| "Android offline speech failed".to_owned());
            return Err(message);
        }
        match result.map_err(|error| error.to_string())?.z() {
            Ok(true) => Ok(()),
            Ok(false) => Err("Android offline speech produced no audio".into()),
            Err(error) => Err(error.to_string()),
        }
    }
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePlatformSpeechCancelled(
    _env: JNIEnv<'_>,
    _activity: JObject<'_>,
    context: jlong,
) -> jboolean {
    if context == 0 {
        return 1;
    }
    let cancellation = &*(context as *const BorrowedCancellation<'_>);
    (cancellation.0)() as jboolean
}

#[no_mangle]
pub unsafe extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_BackgroundChapterWorker_nativePlatformSpeechCancelled(
    env: JNIEnv<'_>,
    worker: JObject<'_>,
    context: jlong,
) -> jboolean {
    Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativePlatformSpeechCancelled(
        env, worker, context,
    )
}

fn read_string(env: &mut JNIEnv<'_>, value: JString<'_>) -> Result<String, String> {
    env.get_string(&value)
        .map(|value| value.to_string_lossy().into_owned())
        .map_err(|error| error.to_string())
}
