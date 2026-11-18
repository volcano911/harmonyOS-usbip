# spdlog 走 header-only（宏 SPDLOG_HEADER_ONLY），目标由上层 CMakeLists 定义。
# 与 Findasio.cmake 同理：只为让 usbipdcpp 的 find_package(spdlog REQUIRED) 通过。
if (TARGET spdlog::spdlog)
    set(spdlog_FOUND TRUE)
else ()
    set(spdlog_FOUND FALSE)
endif ()
