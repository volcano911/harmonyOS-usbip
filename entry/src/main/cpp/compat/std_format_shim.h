/*
 * std_format_shim.h —— 把 std::format 接到 fmt 上
 *
 * 背景（本移植最脏的一处妥协）：
 *   OHOS SDK 自带 libc++ 15，其 <format> 被 _LIBCPP_HAS_NO_INCOMPLETE_FORMAT
 *   默认关闭，只有定义 _LIBCPP_ENABLE_EXPERIMENTAL 才放行。但放行之后，
 *   头文件里的 format_error 是 _LIBCPP_EXPORTED_FROM_ABI 的外部符号，而设备上
 *   的 libc++.so 并没有启用实验特性，因此既不导出 vtable/typeinfo，链接期就报
 *   `undefined symbol: vtable for std::__n1::format_error`，即便强行忽略，
 *   运行期一抛 format_error 也会炸。
 *
 * 办法：
 *   不启用 libc++ 的实验 format（保持 _LIBCPP_HAS_NO_INCOMPLETE_FORMAT 生效，
 *   此时 <format> 展开为空），改用 spdlog 自带的 fmt 11 实现，并把 std::format
 *   直接映射过去。usbipdcpp 全库只有 14 处 std::format 调用，且格式串**全部是
 *   字面量**（没有 vformat / format_to / 自定义 formatter / std::print），
 *   所以这一个函数就够，且能在编译期做格式检查。
 *
 * 这个头文件通过 -include 强制注入每个 C++ 编译单元，早于任何 <format> 的包含。
 */
#ifndef USBIP_STD_FORMAT_SHIM_H
#define USBIP_STD_FORMAT_SHIM_H

#include <string>
#include <utility>

#include <spdlog/fmt/fmt.h>

namespace std {

template <typename... Args>
inline ::std::string format(::fmt::format_string<Args...> fmt_str, Args &&...args) {
    return ::fmt::format(fmt_str, ::std::forward<Args>(args)...);
}

} // namespace std

#endif /* USBIP_STD_FORMAT_SHIM_H */
