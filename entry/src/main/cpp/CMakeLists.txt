cmake_minimum_required(VERSION 3.22.1)
project(org_tasks_harmony)

set(RUST_WORKSPACE_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../..")
set(RUST_MANIFEST "${RUST_WORKSPACE_ROOT}/Cargo.toml")
find_program(CARGO_EXECUTABLE cargo REQUIRED)

if(OHOS_ARCH STREQUAL "arm64-v8a")
  set(RUST_TARGET "aarch64-unknown-linux-ohos")
  set(RUST_LINKER "${OHOS_SDK_NATIVE}/llvm/bin/aarch64-unknown-linux-ohos-clang")
else()
  message(FATAL_ERROR "Rust Harmony bridge currently supports only arm64-v8a; received ${OHOS_ARCH}")
endif()

string(TOUPPER "${RUST_TARGET}" RUST_TARGET_ENV)
string(REPLACE "-" "_" RUST_TARGET_ENV "${RUST_TARGET_ENV}")
set(RUST_STATIC_LIBRARY "${RUST_WORKSPACE_ROOT}/target/${RUST_TARGET}/release/liborg_tasks_harmony.a")

file(GLOB_RECURSE RUST_SOURCES CONFIGURE_DEPENDS
  "${RUST_WORKSPACE_ROOT}/Cargo.toml"
  "${RUST_WORKSPACE_ROOT}/Cargo.lock"
  "${RUST_WORKSPACE_ROOT}/core/src/*.rs"
  "${RUST_WORKSPACE_ROOT}/harmony/src/*.rs")

add_custom_command(
  OUTPUT "${RUST_STATIC_LIBRARY}"
  COMMAND ${CMAKE_COMMAND} -E env
    "CARGO_TARGET_${RUST_TARGET_ENV}_LINKER=${RUST_LINKER}"
    ${CARGO_EXECUTABLE} build --manifest-path "${RUST_MANIFEST}" --package org-tasks-harmony --target ${RUST_TARGET} --release
  WORKING_DIRECTORY "${RUST_WORKSPACE_ROOT}"
  DEPENDS ${RUST_SOURCES}
  COMMENT "编译 Rust Harmony 核心静态库")

add_custom_target(org_tasks_rust_core DEPENDS "${RUST_STATIC_LIBRARY}")

add_library(org_tasks_harmony SHARED napi_init.cpp)
add_dependencies(org_tasks_harmony org_tasks_rust_core)
target_link_libraries(org_tasks_harmony PRIVATE "${RUST_STATIC_LIBRARY}" libace_napi.z.so dl m)
