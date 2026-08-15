cmake_minimum_required(VERSION 3.16)
project(Quorador CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

add_executable(Quorador src/main.cpp)

# ---- SDL2 ----
# On macOS / Linux we look it up the normal way (Homebrew / system package).
# For the mingw Windows cross-build, build.sh points CMAKE_PREFIX_PATH at the
# extracted SDL2-devel-mingw package instead, so find_package still works.
find_package(SDL2 QUIET)
if(SDL2_FOUND)
    target_include_directories(Quorador PRIVATE ${SDL2_INCLUDE_DIRS})
    target_link_libraries(Quorador PRIVATE ${SDL2_LIBRARIES})
else()
    # Fallback to pkg-config (common on Linux / Homebrew installs without CMake config files)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SDL2PKG REQUIRED sdl2)
    target_include_directories(Quorador PRIVATE ${SDL2PKG_INCLUDE_DIRS})
    target_link_libraries(Quorador PRIVATE ${SDL2PKG_LIBRARIES})
    target_link_directories(Quorador PRIVATE ${SDL2PKG_LIBRARY_DIRS})
endif()

if(WIN32)
    # Statically link the C++/GCC runtime and SDL2 itself so Quorador.exe
    # runs on a clean Windows 7 SP1+ machine with no extra DLLs required.
    target_link_options(Quorador PRIVATE -static -static-libgcc -static-libstdc++)
    target_link_libraries(Quorador PRIVATE mingw32 SDL2main SDL2 winmm imm32 version setupapi ole32 oleaut32 uuid)
    target_link_options(Quorador PRIVATE -mwindows)
endif()

if(APPLE)
    target_link_libraries(Quorador PRIVATE "-framework CoreAudio" "-framework AudioToolbox" "-framework CoreVideo" "-framework Cocoa" "-framework IOKit" "-framework ForceFeedback" "-framework Carbon" "-framework Metal" "-framework QuartzCore" "-framework GameController")
endif()

if(UNIX AND NOT APPLE)
    find_package(Threads REQUIRED)
    target_link_libraries(Quorador PRIVATE Threads::Threads)
endif()

target_compile_options(Quorador PRIVATE -O2)
