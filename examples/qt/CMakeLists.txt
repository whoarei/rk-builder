cmake_minimum_required(VERSION 3.16)
project(qt_cross_smoke LANGUAGES CXX)

set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Widgets Svg)

add_executable(qt-cross-smoke main.cpp)
target_link_libraries(qt-cross-smoke PRIVATE Qt6::Widgets Qt6::Svg)
target_compile_features(qt-cross-smoke PRIVATE cxx_std_17)

