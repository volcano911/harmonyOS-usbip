# Android-Usbipdcpp → 鸿蒙原生版：移植记录

目标：把 `yunsmall/Android-Usbipdcpp`（USB/IP 服务端 App）改写成 HarmonyOS NEXT 原生应用。

当前状态：**已在本机构建出可安装的 unsigned HAP**（3.94 MB，含 `libusbip_napi.so`）。
实机 USB 通道尚未验证（构建时无设备连接），验证方法见文末。

---

## 一、可行性结论与证据

核心链路只有一条：**ArkTS 拿到 USB 设备的 fd → 交给 native 的 libusb**。

| 环节 | Android 原版 | 鸿蒙版 | 依据 |
|---|---|---|---|
| 设备枚举 | `UsbManager.getDeviceList()` | `usbManager.getDevices()` | 本地 SDK `@ohos.usbManager.d.ts`，`@since 18`，无系统权限要求 |
| 用户授权 | `requestPermission()` | `usbManager.requestRight(name)` | 同上 |
| 打开设备 | `UsbDeviceConnection` | `usbManager.connectDevice(device)` → `USBDevicePipe` | 同上 |
| 取 fd | `getFileDescriptor()` | `usbManager.getFileDescriptor(pipe)` | 同上，`@since 18` |
| 交给 libusb | `libusb_wrap_sys_device(fd)` | **完全相同** | 上游 `usbipd_jni.cpp` 就是这么做的 |
| 接口 claim | libusb 内部 ioctl | **必须交给 libusb**，不能调 `usbManager.claimInterface()` | 华为官方 FAQ：usbManager claim 后服务进程独占接口，libusb 的 `USBDEVFS_SUBMITURB` 会 EBUSY(errno=16) |

两个关键正面证据：

1. 华为开发者联盟官方博客《HarmonyOS 使用 libusb：从交叉编译到 Native 调用的完整流程》，
   给的正是「ArkTS 取 fd → 传 native → libusb 用」，参考工程 `gitee.com/yuzhiqiang-ten/oh-libusb_test`。
2. 应用市场已有同类成品 `cn.axi.usbip`（阿西西 USBIP 鸿蒙版），说明这条路在零售机上真的能跑通。

结论：**不用重写，是"搬 + 补丁"**。usbipdcpp 的 C++ 主体一行没改语义，唯一改动是
替换了一个 C++20 语法糖；服务端甚至已经有现成的 `bind_host_device_with_wrapped_fd(intptr_t fd)`
入口（原本为 Termux 准备的），鸿蒙直接对位。

---

## 二、工程结构

```
D:\hm-tmp\src\usbip-hm\
├── AppScope\app.json5                 bundleName com.zhoucan.usbip
├── build.ps1                          构建脚本（务必保持纯 ASCII，见文末坑）
├── entry\src\main\
│   ├── module.json5                   INTERNET / GET_NETWORK_INFO / KEEP_BACKGROUND_RUNNING
│   ├── ets\
│   │   ├── entryability\EntryAbility.ets
│   │   ├── pages\Index.ets            状态卡 + 设备列表 + 日志
│   │   └── usbip\UsbDeviceService.ets usbManager 封装（fd 的获取与生命周期）
│   └── cpp\
│       ├── CMakeLists.txt             依赖装配总入口
│       ├── usbip_napi.cpp             Node-API 桥（对应上游 usbipd_jni.cpp）
│       ├── compat\std_format_shim.h   std::format → fmt（clang15 妥协）
│       ├── cmake\Findasio.cmake       find_package 兜底
│       ├── cmake\Findspdlog.cmake
│       └── third_party\libusb\        手写 CMake + 手写 config.h
└── patches\usbipdcpp-ohos.patch       依赖侧补丁（升级依赖时重放）
```

第三方源码放在 `D:\hm-tmp\dl\`（asio 1.30.2 / spdlog 1.15.1 / libusb 1.0.30 / usbipdcpp），
不进工程树；`DEPS_ROOT` 环境变量或 CMakeLists 里的默认值指向它。

## 三、napi 接口

| 函数 | 语义 |
|---|---|
| `init()` | 幂等初始化 libusb，返回是否成功 |
| `probeFd(fd)` | 只读探测：wrap → 读描述符 → 返回可读字符串。**这是验证 fd 通不通的探针** |
| `bindDevice(fd)` | 绑定导出，返回错误码（0 成功） |
| `getLastBusid()` | 最近一次绑定成功拿到的 busid |
| `unbindDevice(fd)` | 按 fd 解绑 |
| `startServer(port)` | 启动，返回实际监听端口，失败 -1 |
| `stopServer()` / `isRunning()` | 停止 / 查询 |
| `setLogCallback(cb)` | 把 spdlog 日志经 threadsafe function 甩回 JS 线程 |

错误码沿用 Android 侧那套 0/1/2/3…99 的编号，`usbip_napi.cpp` 与 `Index.ets` 两侧注释都写明要对齐。

---

## 四、改了什么（全部 6 处）

### 依赖侧（3 处，见 `patches/usbipdcpp-ohos.patch`）

1. **`CMakeLists.txt`**：`find_package(PkgConfig)` 分支加 `if (TARGET libusb-1.0)` 前置判断。
   Windows 主机没有 pkg-config 可执行文件，交叉编译时必须用我们自建的 libusb 目标。
2. **`src/LibusbHandler/LibusbServer.cpp`**：
   `alt_endpoints.emplace_back(4 个参数)` → `push_back(UsbEndpoint{...})`。
   原写法依赖 C++20 的「括号聚合初始化」(P0960)，**clang15 不支持，clang16 才有**；
   OHOS SDK 正是 clang 15.0.4。语义等价，另需把 `bmAttributes & 0x03` 显式收窄成 `uint8_t`。

### 工程侧（3 处，全部是"让 clang15 能编"）

3. **`compat/std_format_shim.h` + `-include` 强制注入**：
   OHOS 的 libc++15 里 `<format>` 被 `_LIBCPP_HAS_NO_INCOMPLETE_FORMAT` 默认关闭。
   打开 `_LIBCPP_ENABLE_EXPERIMENTAL` 能编过，但 `format_error` 的 vtable/typeinfo
   在设备 `libc++.so` 里不存在，链接期就报 `undefined symbol: vtable for std::__n1::format_error`，
   就算强行忽略，运行期抛异常也会炸。所以**不启用它的实验 format**，改把 `std::format`
   映射到 spdlog 自带的 fmt 11。上游全库只有 14 处 `std::format`，格式串全是字面量
   （无 `vformat`/`format_to`/自定义 `formatter`/`std::print`），一个函数就够，且仍有编译期检查。
4. **`third_party/libusb/config.h`（手写）**：libusb 只提供 autotools，`libusbi.h` 却无条件
   `#include <config.h>`。按 OHOS 实际能力固化：`PLATFORM_POSIX`、`HAVE_EVENTFD`、
   `HAVE_TIMERFD`、`HAVE_CLOCK_GETTIME`（缺这个会链接失败）、不开 `USE_UDEV`、
   不开 syslog。
5. **`third_party/libusb/CMakeLists.txt`（手写）**：只编 linux_usbfs 后端的 10 个源文件，
   等价于 `Makefile.am` 里 `OS_LINUX` + 非 udev 分支。另铺一层
   `include/libusb-1.0/libusb.h` 垫片 —— usbipdcpp 按「安装后」布局写 include，
   源码树里没有这个目录层级。
6. **`build.ps1`**：hvigor 走 PowerShell 链路（`hvigorw.bat` + JDK17 + `_JAVA_OPTIONS=-Xms32m -Xmx512m`），
   **文件必须纯 ASCII**：Windows PowerShell 5.1 对无 BOM 的 .ps1 按 ANSI 解码，
   中文注释会让解析断在变量赋值处（现象是 `$HOME_DIR` 为空、进而 `spawn java ENOENT`）。

---

## 五、已知风险（按严重度）

1. **fd 是不是真 usbfs fd** —— 整条链路的前提。若 OHOS 给的是 IPC 管道而非 usbfs 节点，
   `libusb_wrap_sys_device` 会失败。先跑 `probeFd` 看结果。
   （现有证据：华为官方 FAQ 里 `ioctl(fd, IOCTL_USBFS_SUBMITURB, urb)` 返回 EBUSY(errno=16)，
   说明确实是 usbfs 且内核认这个 fd。）
   **已踩坑**：沙箱里 `/dev/bus/usb` 和 `/sys/bus/usb/devices` 全是 Permission denied
   （连 hdc shell 的 uid 2000 都被拒）。`libusb_init` 的 linux_usbfs 后端 `op_init` 会
   先 `linux_start_event_monitor()`（netlink）再 `linux_scan_devices()`（opendir 那两个目录），
   任一失败就返回 `LIBUSB_ERROR_OTHER`，表现为 `libusb_init failed: Other error`。
   **解法**：init 之前 `libusb_set_option(NULL, LIBUSB_OPTION_NO_DEVICE_DISCOVERY)`。
   源码依据（libusb 1.0.30 `os/linux_usbfs.c` 的 `op_init`）：
   ```c
   if (cpriv->no_device_discovery) {
       return LIBUSB_SUCCESS;   // 在 netlink 和 scan 之前返回
   }
   ```
   注意这个开关是「后端特定选项」，要后端实现了 `set_option` 才生效；
   linux_usbfs 的 `op_set_option` 里确实处理了它，否则会返回 `NOT_SUPPORTED`。

   **但开关兜不住更靠前的一处**：`op_init` 第一件事是 `get_kernel_version()`，
   它用 `sscanf(uts.release, "%d.%d.%d")` 解析内核版本，而鸿蒙 `uname` 返回的是
   `HongMeng Kernel 1.13.0`（数值是鸿蒙内核版本，不是 Linux 版本），解析失败直接
   `return LIBUSB_ERROR_OTHER`，真机日志：
   ```
   [libusb] [get_kernel_version] failed to parse uname release 'HongMeng Kernel 1.13.0'
   libusb_init failed: Other error (-99)
   ```
   **解法**：打补丁让它在解析失败时假定 `6.1.0` 并返回成功（`patches/libusb-ohos.patch`）。
   注意不要从该字符串里捞数字——`1.13.0` 会撞上 `< 2.6.32` 的 too-old 分支。
   版本号只影响 `max_iso_packet_len` 的取值，假定现代内核是安全的。

   `op_wrap_sys_device` 本身不依赖 sysfs：走 `linux_get_device_address` + `IOCTL_USBFS_CONNECTINFO`，
   `initialize_device(dev, ..., sysfs_dir=NULL, fd)` 有专门分支，禁枚举后 wrap 依旧可用。
2. **系统驱动占用** —— 手机端把 U 盘/音频/摄像头类设备导出时，系统自己的驱动可能已占用接口。
   与 Android 一样，拿不到就报 `CLAIM_INTERFACE_FAILED`。用一个"哑"设备（串口、HID、加密狗）先试。
3. **sysfs 缺失** —— 沙箱里读不到 `/sys/bus/usb/devices`，libusb 会退回用控制传输读描述符；
   `busnum/devnum` 可能取到 0，busid 会退化成端口号。busid 只要在客户端侧唯一即可，不影响功能。
4. **后台保活** —— 已实现，见 `ets/usbip/KeepAlive.ets`。
   - `module.json5` 的 abilities 里加了 `"backgroundModes": ["dataTransfer"]`，
     并声明 `ohos.permission.KEEP_BACKGROUND_RUNNING`。
   - `startServer()` 成功后立刻调 `keepAlive.start(ctx)`（必须在**前台**调用，
     后台申请会失败），停止服务时 `keepAlive.stop()`。
   - 监听 `continuousTaskCancel` / `continuousTaskSuspend`，被系统取消时把原因
     回传 UI 并自动重拉最多 3 次。
   - 为什么是 `dataTransfer` 而不是 `TASK_KEEPING`：后者要求系统应用
     （`startBackgroundRunning` 直接抛 202 Not System App），三方用不了。
   - 边界：用户手动划掉任务卡，进程仍会结束 —— 这是普通应用绕不过去的。
5. **签名** —— 产物是 unsigned HAP，零售机装不上，需要你自己的调试证书 + Profile（和 wg-client 一样）。
6. **许可证** —— 上游 App 是 GPL-3.0，usbipdcpp 是 LGPLv3 且强制署名。自己用无所谓，
   一旦分发必须开源并署名。

### 自动识别与自动共享（`UsbWatcher.ets` / `DeviceMemory.ets`）

- **鸿蒙没有 USB 热插拔回调**：`@ohos.usbManager` 只有 `getDevices()`，没有
  `on('attach')`；旧 `@ohos.usb` 也没有。唯一的线索是系统公共事件
  `usual.event.hardware.usb.action.USB_DEVICE_ATTACHED / DETACHED`
  （`@ohos.commonEventManager` 的 `Support` 里有定义，注释标明「只能由系统发送」，
  三方能否订阅无保证）。因此做成两层：订阅事件（毫秒级）+ 每 2 秒轮询兜底，
  两者走同一个 diff，重复触发不会重复上报。
- **设备身份不能用 `name`**：`/dev/bus/usb/001/002` 里的 devAddress 每次插拔都变。
  改用 `vid:pid:serial`（`SharedDevice.identity()`）；没有序列号的设备退化成
  `vid:pid:产品名`，两台同型号会被认成同一台，属于可接受误差。
- **名册落盘**用 `@ohos.data.preferences`（库 `usbip_prefs`，键 `remembered_devices`）。
  开关打开 → `remember()`；手动关掉 → `forget()`（自动触发的那次不重复记）。
- **拔出收尾**走新增的 napi `notifyDeviceRemoved(busid)`，而不是 `unbind_by_fd`：
  拔线后 fd 已失效，按 fd 可能查不到；按 busid 移除能保证客户端收到断开、列表也清干净。
- **限制**：`requestRight()` 的授权按设备路径记，重插后 devAddress 变化可能重新弹框；
  系统若不允许后台弹框，需要把 App 切到前台再插一次。

### 保活还需要用户手动开的开关

长时任务只能挡「系统主动冻结」，挡不住这些，装完第一次要手动设：

- 设置 → 应用和元服务 → 应用启动管理 → 找到本应用 → 关掉「自动管理」，
  把「允许自启动 / 允许关联启动 / 允许后台活动」全打开。
- 设置 → WLAN → 更多 WLAN 设置 → 打开「休眠时始终保持网络连接」。

第二条尤其关键：USB/IP 靠 WiFi 走数据，息屏后 WiFi 进省电模式会直接掐断 TCP，
表现为「明明服务还在跑，客户端就是连不上/掉线」。

## 六、怎么继续

```powershell
# 1. 构建
powershell -NoProfile -ExecutionPolicy Bypass -File D:\hm-tmp\src\usbip-hm\build.ps1
# 产物： D:\hm-tmp\out\usbip-1.0.0-api23-arm64-debug-unsigned.hap

# 2. 设备连上后（先签名再装）：
hdc install <signed>.hap
hdc shell hilog | findstr UsbIp

# 3. App 内验证顺序
#    启动服务 → 插一根 USB 设备 → 刷新 → 点「验证通道」
#    期望看到： vid=0x.... pid=0x.... busid=... 
#    然后在 Linux/Windows 客户端：
#    usbip list -r <手机IP>
#    usbip attach -r <手机IP> -b <busid>
```

`probeFd` 返回 "wrap 失败(-...)" 就说明第 5 节风险 1 撞上了，需要换思路
（届时可以退到 `usbManager.bulkTransfer` 手写一个 libusb 后端，工作量从「搬」变成「写」）。
