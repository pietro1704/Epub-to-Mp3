# Reuse a preinstalled compiler cache without installing tools or replacing an
# explicit launcher. Cache keys retain compiler, flags, architecture and inputs.
find_program(CONVERTER_COMPILER_CACHE NAMES sccache ccache)
if(CONVERTER_COMPILER_CACHE)
  foreach(_language C CXX)
    if(NOT DEFINED CMAKE_${_language}_COMPILER_LAUNCHER)
      set(CMAKE_${_language}_COMPILER_LAUNCHER "${CONVERTER_COMPILER_CACHE}"
        CACHE STRING "Native desktop compiler cache")
    endif()
  endforeach()
endif()
