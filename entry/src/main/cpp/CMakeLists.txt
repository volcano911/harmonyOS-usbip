cmake_minimum_required(VERSION 3.5)
project(usbip_napi)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# 第三方源码根目录：asio / spdlog / libusb / usbipdcpp 的 clone 位置。
# 不放进工程树，避免 submodule 的 SSH 地址与体积问题；换机时改这一个变量即可。
# CMake 不会把环境变量当变量读，所以显式取 $ENV{DEPS_ROOT} 兜一层。
if (NOT DEFINED DEPS_ROOT)
    if (DEFINED ENV{DEPS_ROOT})
        set(DEPS_ROOT "$ENV{DEPS_ROOT}")
    else ()
        # 兜底：工程内的 deps/ 目录（加进 .gitignore，clone 依赖后指过来更省事）
        set(DEPS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../deps")
        message(WARNING "usbip: DEPS_ROOT 未设置，回退到 ${DEPS_ROOT}")
    endif ()
endif ()
message(STATUS "usbip: DEPS_ROOT = ${DEPS_ROOT}")

# usbipdcpp 内部用 find_package 找 asio / spdlog，这里用模块模式兜住
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

# ---------------- asio（header-only） ----------------
add_library(asio INTERFACE)
target_include_directories(asio INTERFACE "${DEPS_ROOT}/asio/asio/include")
target_compile_definitions(asio INTERFACE ASIO_STANDALONE ASIO_NO_DEPRECATED)
add_library(asio::asio ALIAS asio)

# ---------------- spdlog（header-only） ----------------
# 用 header-only 而不是 add_subdirectory：省掉 fmt 子目标的构建与 install 规则，
# 也避免 spdlog 的 CMake 对 OHOS 工具链做 MSVC/GCC 分支判断。
# 注意不要再自己 -DSPDLOG_HEADER_ONLY：spdlog/common.h 在未定义 SPDLOG_COMPILED_LIB
# 时会自行定义它，重复定义会触发 -Wmacro-redefined。
add_library(spdlog_ho INTERFACE)
target_include_directories(spdlog_ho INTERFACE "${DEPS_ROOT}/spdlog/include")
add_library(spdlog::spdlog ALIAS spdlog_ho)

# ---------------- libusb（手写 CMake，目标名 libusb-1.0） ----------------
add_subdirectory(third_party/libusb "${CMAKE_CURRENT_BINARY_DIR}/libusb")

# ---------------- std::format → fmt 垫片 ----------------
# 必须放在 libusb 之后（libusb 是纯 C，不需要也不需要 fmt），
# 放在 usbipdcpp 之前（让它和后续所有 C++ 目标都吃到）。
# 详见 compat/std_format_shim.h 顶部的说明。
add_compile_options(-include "${CMAKE_CURRENT_SOURCE_DIR}/compat/std_format_shim.h")

# ---------------- usbipdcpp ----------------
# 只要 libusb 后端：虚拟设备组件（UVC/UAC/MSC 等模拟）全部关掉，少编几万行
set(USBIPDCPP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_EXAMPLE_LIBUSB_SERVER OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_VIRTUAL_DEVICE OFF CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_LIBUSB_COMPONENTS ON CACHE BOOL "" FORCE)
set(USBIPDCPP_BUILD_PYTHON_BINDINGS OFF CACHE BOOL "" FORCE)
# 静态链进 HAP 的 .so：不额外产出一个要单独打包的 libusbipdcpp.so
set(USBIPDCPP_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
# 应用进程里不该由库去接管 SIGINT/SIGTERM —— 那会抢掉 ArkTS 运行时自己的信号处理
set(USBIPDCPP_DISABLE_SIGNAL ON CACHE BOOL "" FORCE)

add_subdirectory("${DEPS_ROOT}/usbipdcpp" "${CMAKE_CURRENT_BINARY_DIR}/usbipdcpp")

# ---------------- napi 桥接层 ----------------
add_library(usbip_napi SHARED usbip_napi.cpp)

target_include_directories(usbip_napi PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

target_link_libraries(usbip_napi
        PUBLIC usbipdcpp_libusb
        PUBLIC ace_napi.z
        PUBLIC hilog_ndk.z
)

# OHOS 的 clang15 对 C++23 的部分特性支持不完整，关掉过于严格的告警噪音
target_compile_options(usbip_napi PRIVATE -Wno-unused-parameter)
