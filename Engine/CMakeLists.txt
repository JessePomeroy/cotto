cmake_minimum_required(VERSION 3.20)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(SottoEngine LANGUAGES C CXX)
endif()

if(NOT APPLE)
    message(FATAL_ERROR "Sotto's native engine currently requires macOS.")
endif()

# A self-contained helper: only system frameworks remain dynamically linked.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(WHISPER_CURL OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(GGML_ACCELERATE ON CACHE BOOL "" FORCE)
set(GGML_BLAS ON CACHE BOOL "" FORCE)
set(GGML_BLAS_VENDOR Apple CACHE STRING "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)

set(WHISPER_SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/../vendor/whisper.cpp")
if(NOT EXISTS "${WHISPER_SOURCE}/include/whisper.h")
    message(FATAL_ERROR "Run git submodule update --init --recursive first.")
endif()
add_subdirectory("${WHISPER_SOURCE}" "${CMAKE_CURRENT_BINARY_DIR}/whisper")

add_executable(sotto-engine worker.cpp)
target_compile_features(sotto-engine PRIVATE cxx_std_17)
target_compile_options(sotto-engine PRIVATE -Wall -Wextra -Wpedantic)
target_include_directories(sotto-engine SYSTEM PRIVATE "${WHISPER_SOURCE}/examples")
target_link_libraries(sotto-engine PRIVATE whisper)
set_target_properties(sotto-engine PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/Engine")
