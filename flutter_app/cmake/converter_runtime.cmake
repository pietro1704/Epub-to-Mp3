# Native desktop product runtime, shared by Linux and Windows Flutter bundles.
get_filename_component(CONVERTER_RUST_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
find_program(CONVERTER_CARGO_EXECUTABLE cargo)
if(NOT CONVERTER_CARGO_EXECUTABLE)
  message(FATAL_ERROR "Cargo is required to build the embedded Piper runtime")
endif()
set(CONVERTER_CARGO_TARGET_DIR "${CONVERTER_RUST_ROOT}/target/flutter-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}"
  CACHE PATH "Isolated native desktop Cargo output")
set(CONVERTER_RUNTIME_STAGE "${CMAKE_BINARY_DIR}/converter-runtime")
if(WIN32)
  set(CONVERTER_FFI_FILENAME "converter_ffi.dll")
else()
  set(CONVERTER_FFI_FILENAME "libconverter_ffi.so")
endif()
set(CONVERTER_FFI_LIBRARY "${CONVERTER_RUNTIME_STAGE}/lib/${CONVERTER_FFI_FILENAME}")
set(_converter_rustflags "$ENV{RUSTFLAGS}")
set(_converter_ort_dynamic 0)
if(WIN32 AND DEFINED ENV{ORT_PREFER_DYNAMIC_LINK})
  # Official Windows shared distributions supply an import library and DLL.
  set(_converter_ort_dynamic "$ENV{ORT_PREFER_DYNAMIC_LINK}")
  if(NOT _converter_ort_dynamic MATCHES "^[01]$")
    message(FATAL_ERROR "ORT_PREFER_DYNAMIC_LINK must be 0 or 1 for Windows packaging")
  endif()
endif()
if(NOT WIN32)
  string(APPEND _converter_rustflags " -C link-arg=-Wl,-rpath,$ORIGIN")
endif()
add_custom_target(converter_ffi_runtime ALL
  COMMAND "${CMAKE_COMMAND}" -E env CARGO_BUILD_JOBS=1 CMAKE_BUILD_PARALLEL_LEVEL=1
    "ORT_PREFER_DYNAMIC_LINK=${_converter_ort_dynamic}" ESPEAK_BUILD_SHARED_LIBS=0 "RUSTFLAGS=${_converter_rustflags}"
    "${CONVERTER_CARGO_EXECUTABLE}" build --locked --release -p converter-ffi
    --features piper-runtime --jobs 1
    --manifest-path "${CONVERTER_RUST_ROOT}/Cargo.toml"
    --target-dir "${CONVERTER_CARGO_TARGET_DIR}"
  COMMAND "${CMAKE_COMMAND}"
    "-DCONVERTER_CARGO_TARGET_DIR=${CONVERTER_CARGO_TARGET_DIR}"
    "-DCONVERTER_RUNTIME_STAGE=${CONVERTER_RUNTIME_STAGE}"
    "-DCONVERTER_FFI_FILENAME=${CONVERTER_FFI_FILENAME}"
    -P "${CMAKE_CURRENT_LIST_DIR}/stage_converter_runtime.cmake"
  BYPRODUCTS "${CONVERTER_FFI_LIBRARY}"
    "${CONVERTER_RUNTIME_STAGE}/data/espeak-ng-data/phontab"
  WORKING_DIRECTORY "${CONVERTER_RUST_ROOT}"
  VERBATIM)
add_dependencies(${BINARY_NAME} converter_ffi_runtime)
