use super::*;
use std::{ffi::CString, io::Write, ptr};
use zip::{write::FileOptions, ZipWriter};

include!("ffi_tests/platform_and_options_contract_tests.rs");
include!("ffi_tests/legacy_identity_contract_tests.rs");
include!("ffi_tests/control_and_streaming_contract_tests.rs");
include!("ffi_tests/typed_options_contract_tests.rs");
include!("ffi_tests/recovery_policy_contract_tests.rs");
include!("ffi_tests/recovery_identity_contract_tests.rs");
include!("ffi_tests/recovery_tamper_contract_tests.rs");
include!("ffi_tests/cached_control_contract_tests.rs");
include!("ffi_tests/session_catalog_contract_tests.rs");
