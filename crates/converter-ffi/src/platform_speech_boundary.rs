use super::*;

pub(super) struct PlatformCancellation<'a> {
    pub(super) cancelled: &'a (dyn Fn() -> bool + Sync),
}

pub(super) unsafe extern "C" fn platform_cancelled(context: *const c_void) -> bool {
    if context.is_null() {
        return true;
    }
    let cancellation = &*context.cast::<PlatformCancellation<'_>>();
    (cancellation.cancelled)()
}

struct CPlatformTts {
    callback: unsafe extern "C" fn(
        *const c_char,
        *const c_char,
        *const c_char,
        ConverterPlatformCancelled,
        *const c_void,
        *mut c_char,
        u32,
        *mut c_void,
    ) -> bool,
    context: usize,
}

impl converter_core::platform_tts::PlatformTts for CPlatformTts {
    fn synthesize_wav(
        &self,
        text: &str,
        language: &str,
        output: &Path,
        cancelled: &(dyn Fn() -> bool + Sync),
    ) -> Result<(), String> {
        let text = CString::new(text).map_err(|_| "Speech text contains NUL")?;
        let language = CString::new(language).map_err(|_| "Speech language contains NUL")?;
        let output = CString::new(output.to_string_lossy().as_bytes())
            .map_err(|_| "Speech output path contains NUL")?;
        let cancellation = PlatformCancellation { cancelled };
        let mut error = [0 as c_char; 1024];
        let success = unsafe {
            (self.callback)(
                text.as_ptr(),
                language.as_ptr(),
                output.as_ptr(),
                platform_cancelled,
                (&cancellation as *const PlatformCancellation<'_>).cast(),
                error.as_mut_ptr(),
                error.len() as u32,
                self.context as *mut c_void,
            )
        };
        if success {
            return Ok(());
        }
        error[1023] = 0;
        let message = unsafe { CStr::from_ptr(error.as_ptr()) }.to_string_lossy();
        Err(if message.is_empty() {
            "The installed offline system voice could not synthesize speech".to_owned()
        } else {
            message.into_owned()
        })
    }
}

/// Installs a session-scoped system speech adapter. Configure only while no
/// conversion is active. `context` must stay alive through all conversions and
/// the caller must not retain cancellation pointers after its callback returns.
/// Passing no callback removes the adapter and restores the original policy.
#[no_mangle]
pub unsafe extern "C" fn converter_session_set_platform_tts_v1(
    handle: *mut ConverterSession,
    callback: ConverterPlatformTtsCallback,
    context: *mut c_void,
) -> bool {
    clear_last_error();
    let Some(session) = handle.as_mut() else {
        return fail("invalid null session handle".to_owned());
    };
    session.platform_tts = callback.map(|callback| {
        Arc::new(CPlatformTts {
            callback,
            context: context as usize,
        }) as Arc<dyn converter_core::platform_tts::PlatformTts>
    });
    true
}

/// Registers the owned installed desktop backend; no synchronous Dart callback.
/// Configure only while no conversion is active. No package is installed.
#[no_mangle]
pub unsafe extern "C" fn converter_session_set_desktop_platform_tts_v1(
    handle: *mut ConverterSession,
) -> bool {
    clear_last_error();
    let Some(session) = handle.as_mut() else {
        return fail("invalid null session handle".into());
    };
    #[cfg(any(target_os = "linux", target_os = "windows"))]
    {
        session.platform_tts = Some(Arc::new(
            converter_core::desktop_tts::DesktopPlatformTts::default(),
        ));
        true
    }
    #[cfg(not(any(target_os = "linux", target_os = "windows")))]
    {
        let _ = session;
        fail("This platform requires its app-provided speech adapter".into())
    }
}
