use super::*;

/// Sets the CPU share local synthesis may use while the app is in the background, as a percent of one core
/// (1..=100), or lifts the limit with 0 when the app returns to the foreground. The limit is process-wide because
/// the operating system's background CPU budget is per process (iOS kills a process above 80% over 60 s).
#[no_mangle]
pub unsafe extern "C" fn converter_set_background_cpu_limit_v1(percent: u32) {
    ffi_guard("converter_set_background_cpu_limit_v1", (), || {
        converter_core::worker::background_pacing::set_background_cpu_limit_percent(percent);
    });
}

/// The limit currently in force (0 = none).
#[no_mangle]
pub unsafe extern "C" fn converter_background_cpu_limit_v1() -> u32 {
    ffi_guard("converter_background_cpu_limit_v1", 0, || {
        converter_core::worker::background_pacing::background_cpu_limit_percent()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_background_limit_round_trips_through_the_c_abi_and_is_lifted_by_zero() {
        unsafe {
            converter_set_background_cpu_limit_v1(50);
            assert_eq!(converter_background_cpu_limit_v1(), 50);
            converter_set_background_cpu_limit_v1(0);
            assert_eq!(converter_background_cpu_limit_v1(), 0);
        }
    }
}
