# 手写 libusb 构建脚本。
#
# libusb 1.0.30 只提供 autotools（Makefile.am）与 msvc 工程，没有 CMakeLists，
# 而 OHOS 的 hvigor 只会用 CMake 驱动 externalNativeOptions。此处只编
# linux_usbfs 后端所需的 10 个源文件，等价于 Makefile.am 里
# `OS_LINUX` + 非 udev 分支的组合。
#
# 目标名刻意取 `libusb-1.0`：usbipdcpp 的 CMakeLists 认这个名字
# （见 usbipdcpp/CMakeLists.txt 的 libusb 分支，本项目对其做了最小补丁）。

if (NOT DEFINED DEPS_ROOT)
    message(FATAL_ERROR "DEPS_ROOT 未定义（应指向存放 libusb 源码的目录）")
endif ()

set(LIBUSB_SRC "${DEPS_ROOT}/libusb/libusb")

add_library(libusb-1.0 STATIC
        ${LIBUSB_SRC}/core.c
        ${LIBUSB_SRC}/descriptor.c
        ${LIBUSB_SRC}/hotplug.c
        ${LIBUSB_SRC}/io.c
        ${LIBUSB_SRC}/strerror.c
        ${LIBUSB_SRC}/sync.c
        ${LIBUSB_SRC}/os/events_posix.c
        ${LIBUSB_SRC}/os/threads_posix.c
        ${LIBUSB_SRC}/os/linux_usbfs.c
        ${LIBUSB_SRC}/os/linux_netlink.c
)

# config.h 放在本目录（先于上游源码目录被搜索到），屏蔽 autotools 依赖
target_include_directories(libusb-1.0
        PUBLIC ${LIBUSB_SRC}
        PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}
)

# ---------------------------------------------------------------------------
# 公共头文件布局垫片
#
# usbipdcpp 一律按「安装后」的布局写 #include <libusb-1.0/libusb.h>，而源码树里
# 头文件是 libusb/libusb.h（即 <libusb/libusb.h>）。这里在构建目录里铺一层
# include/libusb-1.0/libusb.h（内容与源码树一致），把该目录加进 PUBLIC
# 接口，两条路径就都通了。
# ---------------------------------------------------------------------------
set(LIBUSB_SHIM_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/include")
file(MAKE_DIRECTORY "${LIBUSB_SHIM_INCLUDE}/libusb-1.0")
configure_file("${LIBUSB_SRC}/libusb.h" "${LIBUSB_SHIM_INCLUDE}/libusb-1.0/libusb.h" COPYONLY)
target_include_directories(libusb-1.0 PUBLIC ${LIBUSB_SHIM_INCLUDE})

target_compile_definitions(libusb-1.0 PUBLIC _GNU_SOURCE)

# libusb 大量使用 C99/C11 语法与 POSIX 接口，别让 clang 的严格模式拦下来
target_compile_options(libusb-1.0 PRIVATE -Wno-unused-parameter -Wno-sign-compare)

find_package(Threads REQUIRED)
target_link_libraries(libusb-1.0 PUBLIC Threads::Threads)
