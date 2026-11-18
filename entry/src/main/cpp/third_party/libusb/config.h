/*
 * 手写 config.h —— 替代 libusb 的 autotools 产物。
 *
 * 上游 libusb 只提供 autotools/msvc 构建，libusbi.h 第 27 行无条件
 * `#include <config.h>`。本机是 Windows 主机交叉编译 aarch64-linux-ohos，
 * 没有 configure 链路，因此按 OHOS（Linux 内核 + musl/ohos libc）的实际能力
 * 固化这些宏：取值参照 configure.ac 在 Linux 上探测的结果。
 *
 * 关键取舍：
 *   - 保持 USE_UDEV 未定义 —— OHOS 应用沙箱里没有 udev，libusb 走
 *     linux_netlink.c 的热插拔后端；本项目关闭热插拔（set_hotplug_enabled(false)），
 *     只为满足链接。
 *   - HAVE_EVENTFD / HAVE_TIMERFD：OHOS 内核支持，events_posix.c 走无轮询路径。
 *   - USE_SYSTEM_LOGGING_FACILITY 关闭 —— 否则 libusb 往 /dev/log 写，沙箱里
 *     没有 syslog socket，纯浪费。
 */
#ifndef LIBUSB_OHOS_CONFIG_H
#define LIBUSB_OHOS_CONFIG_H

#define _GNU_SOURCE 1

#define DEFAULT_VISIBILITY __attribute__((visibility("default")))
#define PRINTF_FORMAT(a, b) __attribute__((__format__(__printf__, a, b)))

#define PLATFORM_POSIX 1

#define ENABLE_LOGGING 1

#define HAVE_SYS_TIME_H 1
#define HAVE_EVENTFD 1
#define HAVE_TIMERFD 1
/* libusbi.h 第 550 行按此宏二选一：定义了就用内联 clock_gettime，否则要求
 * 后端自己实现 usbi_get_monotonic_time / usbi_get_real_time（我们没有后端实现，
 * 会链接失败）。OHOS 内核提供 clock_gettime，定义掉。 */
#define HAVE_CLOCK_GETTIME 1

#endif /* LIBUSB_OHOS_CONFIG_H */
