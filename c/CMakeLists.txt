cmake_minimum_required(VERSION 3.28)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_BUILD_TYPE Debug)

project(test LANGUAGES CXX)
add_executable(test test.cpp)
target_include_directories(test PRIVATE "${CMAKE_SOURCE_DIR}/../include")
target_link_libraries(test ${CMAKE_SOURCE_DIR}/../zig-out/lib/librdepinfo.a)
