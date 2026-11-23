/// Process-wide background CPU limit for local synthesis (0 lifts it). Pure and
/// instant: it only stores an atomic, so it must not wait behind a conversion.
#[no_mangle]
pub extern "system" fn Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeSetBackgroundCpuLimit(
    env: JNIEnv<'_>,
    _class: JClass<'_>,
    percent: jint,
) {
    super::panic_boundary::jni_guard(
        env.get_raw(),
        "Java_com_pietrocode_epubtomp3_flutter_1app_MainActivity_nativeSetBackgroundCpuLimit",
        (),
        || unsafe { crate::converter_set_background_cpu_limit_v1(percent.max(0) as u32) },
    )
}
