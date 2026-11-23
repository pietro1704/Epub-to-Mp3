use super::*;
use std::{ffi::CString, ptr};
#[path = "../../converter-core/tests/support/epub_fixture.rs"]
mod epub_fixture;

include!("ffi_tests/platform_and_options_contract_tests.rs");
include!("ffi_tests/conversion_fixtures.rs");
include!("ffi_tests/control_and_streaming_contract_tests.rs");
include!("ffi_tests/typed_options_contract_tests.rs");
include!("ffi_tests/recovery_policy_contract_tests.rs");
include!("ffi_tests/recovery_identity_contract_tests.rs");
include!("ffi_tests/recovery_tamper_contract_tests.rs");
include!("ffi_tests/cached_control_contract_tests.rs");
include!("ffi_tests/session_catalog_contract_tests.rs");
include!("ffi_tests/language_model_contract_tests.rs");
include!("ffi_tests/model_install_operation_contract_tests.rs");
include!("ffi_tests/listening_contract_tests.rs");
include!("ffi_tests/installed_piper_session_tests.rs");
include!("ffi_tests/panic_boundary_contract_tests.rs");
include!("ffi_tests/library_metadata_contract_tests.rs");
include!("ffi_tests/chapter_footnotes_contract_tests.rs");
include!("ffi_tests/error_code_contract_tests.rs");

#[path = "ffi_tests/pdf_contract_tests.rs"]
mod pdf_contract_tests;
