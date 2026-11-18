# asio 走 header-only，本工程的 CMakeLists 已直接定义 asio::asio 目标。
# usbipdcpp 内部有 `find_package(asio REQUIRED)`，该调用在 config 模式找不到
# 已安装的 asio 后会落到模块模式，命中本文件。这里只负责让 find_package
# 认为"找到了"，目标本身由上层提供。
if (TARGET asio::asio)
    set(asio_FOUND TRUE)
else ()
    set(asio_FOUND FALSE)
endif ()
