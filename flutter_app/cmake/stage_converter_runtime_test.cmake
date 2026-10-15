cmake_minimum_required(VERSION 3.13)
set(_fixture "${CMAKE_CURRENT_LIST_DIR}/../../.reports/tts-preferences/desktop-packaging-fixture")
file(REMOVE_RECURSE "${_fixture}")
set(_profile "${_fixture}/target/release")
set(_data "${_profile}/build/espeak-rs-sys-fixture/out/build/espeak-ng-data")
file(MAKE_DIRECTORY "${_data}/lang/roa")
foreach(_asset phontab phondata phonindex lang/roa/pt)
  file(WRITE "${_data}/${_asset}" "fixture-${_asset}")
endforeach()
foreach(_ffi libconverter_ffi.so converter_ffi.dll)
  file(WRITE "${_profile}/${_ffi}" "fixture-native-library")
  file(WRITE "${_profile}/libonnxruntime.so.1" "fixture-ort-library")
  execute_process(COMMAND "${CMAKE_COMMAND}"
    "-DCONVERTER_CARGO_TARGET_DIR=${_fixture}/target"
    "-DCONVERTER_RUNTIME_STAGE=${_fixture}/stage"
    "-DCONVERTER_FFI_FILENAME=${_ffi}"
    -P "${CMAKE_CURRENT_LIST_DIR}/stage_converter_runtime.cmake" RESULT_VARIABLE _result)
  if(NOT _result EQUAL 0)
    message(FATAL_ERROR "Desktop runtime staging failed for ${_ffi}")
  endif()
  foreach(_path "lib/${_ffi}" lib/libonnxruntime.so.1 data/espeak-ng-data/phontab data/espeak-ng-data/lang/roa/pt)
    if(NOT EXISTS "${_fixture}/stage/${_path}")
      message(FATAL_ERROR "Desktop bundle is missing ${_path}")
    endif()
  endforeach()
endforeach()
file(REMOVE "${_data}/phondata")
execute_process(COMMAND "${CMAKE_COMMAND}"
  "-DCONVERTER_CARGO_TARGET_DIR=${_fixture}/target"
  "-DCONVERTER_RUNTIME_STAGE=${_fixture}/stage"
  -DCONVERTER_FFI_FILENAME=converter_ffi.dll
  -P "${CMAKE_CURRENT_LIST_DIR}/stage_converter_runtime.cmake"
  RESULT_VARIABLE _missing_data OUTPUT_QUIET ERROR_QUIET)
if(_missing_data EQUAL 0)
  message(FATAL_ERROR "Incomplete phonemizer data must fail packaging")
endif()
file(REMOVE_RECURSE "${_fixture}")
message(STATUS "Desktop runtime staging fixture passed")
