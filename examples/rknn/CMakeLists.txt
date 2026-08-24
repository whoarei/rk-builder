cmake_minimum_required(VERSION 3.16)
project(rknn_smoke C)

find_package(PkgConfig REQUIRED)
pkg_check_modules(RKNNRT REQUIRED IMPORTED_TARGET rknnrt)

add_executable(rknn-smoke main.c)
target_compile_features(rknn-smoke PRIVATE c_std_11)
target_link_libraries(rknn-smoke PRIVATE PkgConfig::RKNNRT)
