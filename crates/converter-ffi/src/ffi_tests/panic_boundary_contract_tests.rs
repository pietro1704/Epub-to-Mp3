#[test]
fn foreign_boundaries_contain_panics_and_preserve_followup_calls() {
    // An unprotected extern function aborts, so exercise the actual ABI in a
    // child rather than allowing a regression to terminate the test harness.
    for scenario in ["cancellation", "session_drop"] {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", "tests::foreign_boundary_panic_child", "--nocapture"])
            .env("CONVERTER_FFI_PANIC_SCENARIO", scenario)
            .output()
            .unwrap();
        assert!(output.status.success(), "{scenario}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr));
    }
}

#[test]
fn foreign_boundary_panic_child() {
    let Ok(scenario) = std::env::var("CONVERTER_FFI_PANIC_SCENARIO") else { return };
    clear_last_error();
    let expected = match scenario.as_str() {
        "cancellation" => {
            let cancellation = PlatformCancellation { cancelled: &|| panic!("cancellation fixture") };
            assert!(unsafe { platform_cancelled((&cancellation as *const PlatformCancellation<'_>).cast()) });
            "platform_cancelled"
        }
        "session_drop" => {
            struct PanicOnDrop;
            impl converter_core::platform_tts::PlatformTts for PanicOnDrop {
                fn synthesize_wav(&self, _: &str, _: &str, _: &Path, _: &(dyn Fn() -> bool + Sync)) -> Result<(), String> {
                    unreachable!("this fixture only exercises ownership release")
                }
            }
            impl Drop for PanicOnDrop {
                fn drop(&mut self) { panic!("provider destructor fixture"); }
            }
            let book = fixture();
            let path = CString::new(book.path().to_str().unwrap()).unwrap();
            let session = unsafe { converter_session_open(path.as_ptr()) };
            assert!(!session.is_null());
            unsafe {
                (*session).platform_tts = Some(Arc::new(PanicOnDrop));
                converter_session_free(session);
            }
            "converter_session_free"
        }
        _ => panic!("unknown panic fixture"),
    };
    unsafe {
        let error = converter_last_error();
        assert!(!error.is_null());
        let message = CStr::from_ptr(error).to_string_lossy().into_owned();
        converter_string_free(error);
        assert!(message.contains(expected), "{message}");
        assert!(converter_last_error().is_null(), "error ownership must transfer once");
        let control = converter_job_control_create();
        assert!(!control.is_null());
        converter_job_control_cancel(control);
        assert!((*control).control.cancellation_token().is_cancelled());
        converter_job_control_free(control);
        assert!(converter_last_error().is_null(), "next operation must remain usable");
    }
}
