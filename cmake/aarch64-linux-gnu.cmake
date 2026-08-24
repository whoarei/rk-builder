set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(RK_SYSROOT "/opt/sysroot" CACHE PATH "Debian ARM64 target sysroot")

set(CMAKE_C_COMPILER aarch64-linux-gnu-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-gnu-g++)
set(CMAKE_SYSROOT "${RK_SYSROOT}")
set(CMAKE_LIBRARY_ARCHITECTURE aarch64-linux-gnu)

set(CMAKE_FIND_ROOT_PATH "${RK_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_PREFIX_PATH
    "${RK_SYSROOT}/usr/local/ans"
    "${RK_SYSROOT}/usr/lib/aarch64-linux-gnu/cmake"
    "${RK_SYSROOT}/usr/lib/cmake"
    "${RK_SYSROOT}/usr/share/cmake"
)

# Let the linker resolve DT_NEEDED entries of target shared libraries from
# the custom prefix and Debian multiarch directory.  -rpath-link is used only
# while linking and does not add a runtime RPATH to produced binaries.
set(CMAKE_EXE_LINKER_FLAGS_INIT
    "-Wl,-rpath-link,${RK_SYSROOT}/usr/local/ans/lib -Wl,-rpath-link,${RK_SYSROOT}/usr/lib/aarch64-linux-gnu"
)

# Qt target packages remain under the target sysroot. Only executable build
# tools (moc/uic/rcc and friends) are taken from the native amd64 host tree.
if(NOT DEFINED QT_HOST_PATH AND EXISTS "/opt/qt-host/6.2.4")
    set(QT_HOST_PATH "/opt/qt-host/6.2.4" CACHE PATH
        "Qt host tools used while cross-compiling")
endif()

set(ENV{PKG_CONFIG_DIR} "")
set(ENV{PKG_CONFIG_PATH} "")
set(ENV{PKG_CONFIG_LIBDIR}
    "${RK_SYSROOT}/usr/local/ans/lib/pkgconfig:${RK_SYSROOT}/usr/lib/aarch64-linux-gnu/pkgconfig:${RK_SYSROOT}/usr/lib/pkgconfig:${RK_SYSROOT}/usr/share/pkgconfig")
set(ENV{PKG_CONFIG_SYSROOT_DIR} "${RK_SYSROOT}")

find_program(CCACHE_PROGRAM ccache)
if(CCACHE_PROGRAM)
    set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
    set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
endif()
