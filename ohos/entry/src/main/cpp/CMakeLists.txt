# CMake for the eCard bind packet reader (libecardbind_reader.so).
# Compiled by hvigor's externalNativeOptions (see entry/build-profile.json5).
cmake_minimum_required(VERSION 3.10)
project(ecardbind_reader)

set(CMAKE_CXX_STANDARD 17)

add_library(ecardbind_reader SHARED ecardbind_reader.cpp)

# NAPI is provided by the OHOS NDK.
target_link_libraries(ecardbind_reader PUBLIC
    libace_napi.z.so
)
