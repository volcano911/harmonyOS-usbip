# harmonyOS-usbip

> 把鸿蒙手机变成一台 **USB/IP 服务端**：插在手机上的 U 盘、加密狗、串口、打印机、
> HID 设备，可以通过 WiFi 直接「插」到另一台电脑上使用。

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20NEXT-000000.svg)]()
[![API](https://img.shields.io/badge/API-23%20%286.1.0%29-34C759.svg)]()

本项目是 [`yunsmall/Android-Usbipdcpp`](https://github.com/yunsmall/Android-Usbipdcpp)
的 **鸿蒙原生移植版**。协议栈、设备处理和 USB/IP 服务端逻辑全部来自
[`usbipdcpp`](https://github.com/yunsmall/usbipdcpp)，这里做的是把它接到鸿蒙的
USB 权限模型上，并重写了 ArkTS 侧的服务生命周期、自动识别、后台保活和界面。

---

## 它解决什么问题

USB/IP 协议允许把一台机器上的 USB 设备通过网络「导出」，在另一台机器上「导入」，
导入端看到的是一台真正的本地 USB 设备 —— 驱动、软件、授权都照常工作。

```
   ┌──────────────┐                              ┌──────────────┐
   │  鸿蒙手机     │                              │  电脑         │
   │              │         WiFi / TCP           │              │
   │  U 盘 ──┐    │  ◀──────────────────────▶    │  usbip attach│
   │  加密狗 ─┼─ USB │        port 3240           │      │       │
   │  串口  ──┘    │                              │      ▼       │
   │              │                              │  /dev/ttyUSB0│
   │  USB/IP 服务  │                              │  或 COM3     │
   └──────────────┘                              └──────────────┘
```

典型用途：

- 加密狗 / 授权 U 盾装在手机上，笔记本远程调用
- 串口设备（PLC、开发板）没插在工控机上，靠手机中转
- 临时要在另一台机器上用一下 U 盘，不想拔来拔去

## 功能

| 功能 | 说明 |
|---|---|
| USB/IP 服务 | 可配置监听端口（默认 3240），后台常驻 |
| 设备列表 | 实时枚举当前接入的 USB 设备，显示 VID/PID、设备类、设备节点 |
| 一键共享 | 单个开关绑定 / 解绑，绑定后可看到分配到的 busid |
| 验证通道 | 只读探测：把 fd 交给 libusb 读一遍描述符，用于排查「这台设备能不能被抽象出来」 |
| 自动识别 | 插上即出现在列表里（系统公共事件 + 2 秒轮询双通道） |
| 自动共享 | 曾经手动共享过的设备，再插上自动打开，无需操作 |
| 后台保活 | 长时任务（dataTransfer 模式），切后台不会被冻结掉线 |
| 运行日志 | 服务端日志实时回传界面，可分级着色，方便定位问题 |
| 白色 iOS 风界面 | 浅灰底 + 白卡片 + 单一强调蓝 |

## 环境要求

| 项 | 要求 |
|---|---|
| 系统 | HarmonyOS NEXT，API 23（6.1.0）及以上 |
| 架构 | arm64-v8a |
| 设备 | 支持 USB OTG（手机 / 平板 / 2in1） |
| 网络 | 手机与客户端在同一网段，或能互通 3240 端口 |
| 客户端 | Linux 用内核自带 `usbip`；Windows 用 [usbip-win2](https://github.com/vadimgrn/usbip-win2) |

## 安装

到 [Releases](../../releases/latest) 下载 `harmonyos-usbip-*-arm64-unsigned.hap`，同页附件里还有 `SHA256SUMS.txt` 可核对校验值。仓库 `release/` 目录保留了同一份文件，方便 clone 后直接取用。

下载到的是 **未签名** HAP，零售设备装不上，二选一：

**A. DevEco Studio 自动签名**

1. 用 DevEco Studio 打开本工程
2. `File → Project Structure → Signing Configs`，勾选 `Automatically generate signature`
3. 运行到设备

**B. 命令行签名**

```bash
java -jar hap-sign-tool.jar sign-app \
  -keyAlias "<alias>" -signAlg "SHA256withECDSA" \
  -mode "localSign" -appCertFile "<your>.cer" \
  -profileFile "<your>.p7b" -inFile "harmonyos-usbip.hap" \
  -keystoreFile "<your>.p12" -outFile "signed.hap" \
  -keyPwd "<pwd>" -keystorePwd "<pwd>"

hdc install signed.hap
```

签名前先核对下载到的包：

```bash
sha256sum -c SHA256SUMS.txt
```

## 使用

1. 打开 App，点 **启动服务**（默认端口 3240，可改）
2. 用 OTG 线插上要共享的 USB 设备，列表里会自动出现
3. 拨动右侧开关 → 系统弹出授权框 → 允许
4. 开关变成绿色，设备行右侧出现「自动」角标（下次插上会自己打开）
5. 在电脑上：

```bash
# Linux
usbip list -r 192.168.1.50            # 列出手机导出的设备
usbip attach -r 192.168.1.50 -b 1-2:0 # 按 busid 挂载
lsusb                                  # 应该能看到这台设备了

# 用完挂回去
usbip detach -p 00
```

```powershell
# Windows（usbip-win2）
usbip list -r 192.168.1.50
usbip attach -r 192.168.1.50 -b 1-2:0
```

### 想让它长期不掉线，还得手动开两个开关

系统的长时任务只能挡住「系统主动冻结」，下面两项需要自己设一次：

- **设置 → 应用和元服务 → 应用启动管理 → 找到本应用**：关掉「自动管理」，
  把「允许自启动」「允许关联启动」「允许后台活动」全部打开
- **设置 → WLAN → 更多 WLAN 设置**：打开「休眠时始终保持网络连接」

第二条尤其关键。USB/IP 的数据走 WiFi，息屏后 WiFi 进省电模式会直接掐断 TCP，
表现就是「App 明明还显示运行中，客户端却连不上或者突然掉线」。

## 从源码构建

### 依赖

第三方源码不进仓库，需要自己准备（clone 到任意目录，用 `DEPS_ROOT` 指过去）：

| 依赖 | 版本 | 地址 |
|---|---|---|
| usbipdcpp | main | https://github.com/yunsmall/usbipdcpp |
| libusb | 1.0.30 | https://github.com/libusb/libusb |
| Asio | 1.30.2 | https://github.com/chriskohlhoff/asio |
| spdlog | 1.15.1 | https://github.com/gabime/spdlog |

```bash
mkdir -p ~/usbip-deps && cd ~/usbip-deps
git clone https://github.com/yunsmall/usbipdcpp
git clone --branch v1.0.30 https://github.com/libusb/libusb
git clone --branch asio-1-30-2 https://github.com/chriskohlhoff/asio
git clone --branch v1.15.1 https://github.com/gabime/spdlog
```

**必须先应用补丁**，否则 clang 15 编不过、libusb 在鸿蒙上初始化会失败：

```bash
cd ~/usbip-deps/usbipdcpp && git apply <repo>/patches/usbipdcpp-ohos.patch
cd ~/usbip-deps/libusb   && git apply <repo>/patches/libusb-ohos.patch
```

两个补丁分别解决：

- `usbipdcpp-ohos.patch` —— OHOS SDK 是 clang 15，不支持 C++20 的括号聚合初始化
  （P0960，clang 16 才有），把 `emplace_back(a,b,c,d)` 改成显式聚合初始化
- `libusb-ohos.patch` —— libusb 用 `sscanf(uname.release, "%d.%d.%d")` 判断内核版本，
  而鸿蒙返回的是 `HongMeng Kernel 1.13.0`，解析失败直接让 `libusb_init` 返回
  `Other error`。补丁让它解析失败时假定 6.1.0

### 命令行构建（Windows）

```powershell
$env:DEPS_ROOT = 'D:\usbip-deps'
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

产物：`out/usbip-1.0.0-api23-arm64-debug-unsigned.hap`

`build.ps1` 里 `$Root`、`$JavaHome` 是按作者本机写的，换机器要改这两处。
**这个文件必须保持纯 ASCII** —— Windows PowerShell 5.1 对无 BOM 的 `.ps1`
按 ANSI 解码，中文注释会让变量赋值静默失败。

### DevEco Studio 构建

直接 `Open` 工程目录，设置环境变量 `DEPS_ROOT`（或改
`entry/src/main/cpp/CMakeLists.txt` 里的默认值），然后 `Build → Build Hap(s)`。

## 工作原理

整条链路只有一句话：**ArkTS 从 `usbManager` 拿到 USB 设备的 fd，把它交给 native 的 libusb。**

```
ArkTS                            NAPI              C++
─────                            ────              ───
usbManager.getDevices()
usbManager.requestRight()
usbManager.connectDevice()   ─▶  bindDevice(fd) ─▶ libusb_wrap_sys_device(fd)
usbManager.getFileDescriptor()                     usbipdcpp::LibusbServer
                                                     └─ 导出到 TCP 3240
```

几个关键设计决定：

- **绝不调用 `usbManager.claimInterface()`**。一旦调了，USB 服务进程会独占接口，
  之后 libusb 的 `USBDEVFS_SUBMITURB` 一律返回 `EBUSY(16)`。接口必须由 libusb 自己 claim。
- **`LIBUSB_OPTION_NO_DEVICE_DISCOVERY`**。应用沙箱里 `/dev/bus/usb` 和
  `/sys/bus/usb/devices` 全是 `Permission denied`，libusb 初始化时扫这两个目录会直接失败。
  我们的设备全部来自 `usbManager` 授权的 fd，不需要 libusb 自己枚举。
- **不碰 `std::format`**。OHOS 的 libc++ 15 里 `<format>` 默认关闭，强开会在链接期
  报 `undefined symbol: vtable for std::__n1::format_error`（设备上的 `libc++.so`
  没有这个符号）。改成映射到 spdlog 自带的 fmt。
- **后台保活用 `dataTransfer` 模式**，不是 `TASK_KEEPING`。后者要求系统应用，
  三方调用 `startBackgroundRunning` 直接返回 202。
- **状态判断以服务端为准**。界面上的「是否已共享」不是 ArkTS 自己记账，而是每次
  向 native 查一遍 busid 列表。设备枚举会抖动（`connectDevice` 期间系统可能短暂
  少列一台设备），靠界面记账迟早会和真实状态对不上。

更细的移植记录、踩坑和风险清单见 [PORTING.md](PORTING.md)。

## 已知限制

- **速度不如本机直连**。数据要经过 URB 打包 → TCP → 客户端还原这一趟，
  受 WiFi 带宽和往返延迟双重限制。适合打印机、加密狗、串口、HID 这类低速设备；
  大容量存储的持续高速读写体验会明显下降。
- **接口被系统驱动占用时无法共享**。U 盘、摄像头、音频这类设备，系统自己的驱动
  可能已经拿着接口，此时会报 claim 失败。用「哑」设备（串口、HID、加密狗）最容易成功。
- **`requestRight()` 的授权按设备路径记**。重插后 devAddress 变化可能重新弹框；
  如果系统不允许后台弹框，需要把 App 切到前台再插一次。
- **划掉任务卡进程仍会结束**。这是普通应用绕不过去的，长时任务挡不住用户手动清理。
- **只支持 arm64-v8a**。

## 致谢

本项目几乎所有的 USB/IP 工作都来自上游，详见 [NOTICE](NOTICE)：

- [yunsmall/Android-Usbipdcpp](https://github.com/yunsmall/Android-Usbipdcpp) —— 移植蓝本（GPL-3.0）
- [yunsmall/usbipdcpp](https://github.com/yunsmall/usbipdcpp) —— USB/IP 服务端库（LGPLv3）
- [libusb](https://github.com/libusb/libusb) —— 用户态 USB 访问（LGPL-2.1）
- [Asio](https://github.com/chriskohlhoff/asio) —— 异步网络（BSL-1.0）
- [spdlog](https://github.com/gabime/spdlog) —— 日志（MIT）

## 许可

[GPL-3.0](LICENSE)。

因为它是 GPL-3.0 应用的衍生作品，GPL-3.0 是唯一可以再分发的许可。
`usbipdcpp` 以 LGPLv3 静态链入 `libusbip_napi.so`，按 LGPLv3 第 4 条，
本仓库提供了完整对应源码，且所有对 usbipdcpp 的改动都放在
`patches/usbipdcpp-ohos.patch` 里，可以重新编译并重链接。
