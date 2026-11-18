/*
 * usbip_napi.cpp —— Android-Usbipdcpp 的 Node-API 版桥接层
 *
 * 与上游 app/src/main/cpp/usbipd_jni.cpp 一一对位：
 *   JNI 侧 UsbIpNative.kt  →  ArkTS 侧 UsbIpNative.ets
 *   jint fd 参数           →  number fd 参数
 *
 * 三种跨越边界的东西必须小心：
 *   1. C++ 异常不能穿越 napi 边界（ART/ArkTS 都无法 unwind），所有导出函数
 *      一律 try/catch 兜底。
 *   2. 服务端是"一连接一线程"，日志从任意线程产生 —— 用
 *      napi_threadsafe_function 把日志甩回 JS 线程，不能直接 napi_call_function。
 *   3. fd 的所有权：libusb 对 libusb_wrap_sys_device 传入的 fd 会设置 fd_keep，
 *      关闭 libusb_device_handle 不会关掉原 fd，UsbDevicePipe 仍可继续使用。
 */

#include <napi/native_api.h>
#include <hilog/log.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <string>
#include <thread>
#include <vector>

#include <libusb-1.0/libusb.h>
#include <spdlog/spdlog.h>
#include <spdlog/sinks/base_sink.h>

#include <usbipdcpp/Server.h>
#include <usbipdcpp/LibusbHandler/LibusbServer.h>
#include <usbipdcpp/LibusbHandler/LibusbDeviceHandlerConfig.h>
#include <usbipdcpp/LibusbHandler/tools.h>

#define LOG_DOMAIN 0x3200
#define LOG_TAG "UsbIpNapi"

#define LOGI(fmt, ...) OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGW(fmt, ...) OH_LOG_Print(LOG_APP, LOG_WARN, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)
#define LOGE(fmt, ...) OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, fmt, ##__VA_ARGS__)

namespace {

// 错误码：必须与 ArkTS 侧 UsbIpNative.ets 的常量表保持一致
namespace ErrorCode {
    constexpr int SUCCESS = 0;
    constexpr int DEVICE_NOT_FOUND = 1;
    constexpr int DEVICE_IN_USE = 2;
    constexpr int DEVICE_OPEN_FAILED = 3;
    constexpr int GET_DESCRIPTOR_FAILED = 4;
    constexpr int GET_CONFIG_FAILED = 5;
    constexpr int CLAIM_INTERFACE_FAILED = 6;
    constexpr int DEVICE_ALREADY_BOUND = 7;
    constexpr int HUB_FILTERED = 8;
    constexpr int SERVER_NOT_RUNNING = 9;
    constexpr int UNKNOWN_ERROR = 99;
}

std::mutex g_mutex;
std::unique_ptr<usbipdcpp::LibusbServer> g_server;
bool g_initialized = false;
bool g_running = false;
int g_port = -1;
std::string g_last_busid;
napi_threadsafe_function g_log_tsfn = nullptr;

// ---------------------------------------------------------------- 日志汇

/** 把 spdlog 的每条日志丢回 JS 线程（日志可能来自会话线程/发送线程） */
class JsLogSink final : public spdlog::sinks::base_sink<std::mutex> {
protected:
    void sink_it_(const spdlog::details::log_msg &msg) override {
        // 传输热路径上有大量 SPDLOG_DEBUG（每完成一个 URB 一条），跨 napi 送到
        // JS 线程会触发一次界面重排。info 以下只落 hilog，不进 UI。
        if (msg.level < spdlog::level::info) {
            return;
        }
        spdlog::memory_buf_t buf;
        formatter_->format(msg, buf);
        auto *payload = new std::string(buf.data(), buf.size());
        if (g_log_tsfn == nullptr) {
            delete payload;
            return;
        }
        // 非阻塞：队满就直接丢弃并释放，服务端日志不允许反压业务线程
        if (napi_call_threadsafe_function(g_log_tsfn, payload, napi_tsfn_nonblocking) != napi_ok) {
            delete payload;
        }
    }

    void flush_() override {}
};

/** 同时落 hilog，方便 hdc hilog 直接看（UI 未打开时也能排查） */
class HiLogSink final : public spdlog::sinks::base_sink<std::mutex> {
protected:
    void sink_it_(const spdlog::details::log_msg &msg) override {
        spdlog::memory_buf_t buf;
        formatter_->format(msg, buf);
        OH_LOG_Print(LOG_APP, LOG_INFO, LOG_DOMAIN, LOG_TAG, "%{public}s", buf.data());
    }

    void flush_() override {}
};

void CallJsLog(napi_env env, napi_value js_cb, void * /*context*/, void *data) {
    std::unique_ptr<std::string> msg(static_cast<std::string *>(data));
    if (env == nullptr || js_cb == nullptr) {
        return;
    }
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    napi_value argv[1] = {nullptr};
    if (napi_create_string_utf8(env, msg->c_str(), msg->size(), &argv[0]) != napi_ok) {
        return;
    }
    // 回调里抛异常不能冒出来，吞掉即可（日志通道不值得让进程挂）
    napi_call_function(env, undefined, js_cb, 1, argv, nullptr);
    bool pending = false;
    if (napi_is_exception_pending(env, &pending) == napi_ok && pending) {
        napi_value ignored = nullptr;
        napi_get_and_clear_last_exception(env, &ignored);
    }
}

void AttachLogger() {
    auto sinks = std::make_shared<std::vector<spdlog::sink_ptr>>();
    sinks->push_back(std::make_shared<HiLogSink>());
    sinks->push_back(std::make_shared<JsLogSink>());
    auto logger = std::make_shared<spdlog::logger>("usbip", sinks->begin(), sinks->end());
    logger->set_pattern("[%H:%M:%S] [%l] %v");
    // 默认 info：debug 会在每个 URB 完成时打一条，接口一跑起来就是每秒几百条，
    // 既刷爆 hilog 又把 JS 线程拖死。需要时用 setLogLevel(1) 临时打开。
    logger->set_level(spdlog::level::info);
    logger->flush_on(spdlog::level::warn);
    spdlog::set_default_logger(logger);
}

// ---------------------------------------------------------------- 工具

/**
 * libusb 日志桥。
 *
 * libusb 的后端失败原因（opendir 失败、netlink 建 socket 失败、claim 冲突……）
 * 默认只往 stderr 打，而鸿蒙应用里 stderr 直接丢弃。挂个回调转到 hilog，
 * 出问题时 hilog 里就能看到 libusb 自己的原话，不用再靠猜。
 */
void LibusbLogBridge(libusb_context * /*ctx*/, enum libusb_log_level level, const char *str) {
    switch (level) {
        case LIBUSB_LOG_LEVEL_ERROR:
            LOGE("[libusb] %{public}s", str);
            break;
        case LIBUSB_LOG_LEVEL_WARNING:
            LOGW("[libusb] %{public}s", str);
            break;
        default:
            LOGI("[libusb] %{public}s", str);
            break;
    }
}

bool EnsureLibusbLocked() {
    if (g_initialized) {
        return true;
    }
    // 关键：鸿蒙应用沙箱里 /dev/bus/usb 和 /sys/bus/usb/devices 都是 Permission denied
    // （连 hdc shell 都被拒），而 libusb_init 的 linux_usbfs 后端第一件事就是去扫这两个
    // 目录，扫不到直接返回 LIBUSB_ERROR_OTHER。
    //
    // 我们的设备全部来自 usbManager 授权的 fd，靠 libusb_wrap_sys_device 注入，
    // 根本不需要 libusb 自己枚举。所以关掉设备发现，只建上下文。
    // 这个开关必须在第一次 libusb_init 之前用 NULL context 设置，才算全局默认值。
    int opt_err = libusb_set_option(nullptr, LIBUSB_OPTION_NO_DEVICE_DISCOVERY);
    if (opt_err < 0 && opt_err != LIBUSB_ERROR_NOT_SUPPORTED) {
        LOGW("libusb_set_option(NO_DEVICE_DISCOVERY) = %{public}d", opt_err);
    } else {
        LOGI("device discovery disabled (sandbox has no usbfs access)");
    }

    // 把 libusb 自己的错误/警告接到 hilog，省得下次还要靠猜
    libusb_set_option(nullptr, LIBUSB_OPTION_LOG_CB, &LibusbLogBridge);
    libusb_set_option(nullptr, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_WARNING);

    int err = libusb_init(nullptr);
    if (err < 0) {
        LOGE("libusb_init failed: %{public}s (%{public}d)",
             libusb_strerror(static_cast<enum libusb_error>(err)), err);
        return false;
    }
    g_initialized = true;
    const libusb_version *ver = libusb_get_version();
    if (ver != nullptr) {
        LOGI("libusb initialized, %{public}d.%{public}d.%{public}d",
             ver->major, ver->minor, ver->micro);
    }
    return true;
}

int ToErrorCode(usbipdcpp::DeviceOperationResult result) {
    using usbipdcpp::DeviceOperationResult;
    switch (result) {
        case DeviceOperationResult::Success: return ErrorCode::SUCCESS;
        case DeviceOperationResult::DeviceNotFound: return ErrorCode::DEVICE_NOT_FOUND;
        case DeviceOperationResult::DeviceInUse: return ErrorCode::DEVICE_IN_USE;
        case DeviceOperationResult::DeviceAlreadyBound: return ErrorCode::DEVICE_ALREADY_BOUND;
        case DeviceOperationResult::DeviceOpenFailed: return ErrorCode::DEVICE_OPEN_FAILED;
        case DeviceOperationResult::GetDescriptorFailed: return ErrorCode::GET_DESCRIPTOR_FAILED;
        case DeviceOperationResult::GetConfigFailed: return ErrorCode::GET_CONFIG_FAILED;
        case DeviceOperationResult::ClaimInterfaceFailed: return ErrorCode::CLAIM_INTERFACE_FAILED;
        case DeviceOperationResult::HubFiltered: return ErrorCode::HUB_FILTERED;
        default: return ErrorCode::UNKNOWN_ERROR;
    }
}

napi_value MakeString(napi_env env, const std::string &s) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &out);
    return out;
}

napi_value MakeInt(napi_env env, int32_t v) {
    napi_value out = nullptr;
    napi_create_int32(env, v, &out);
    return out;
}

napi_value MakeBool(napi_env env, bool v) {
    napi_value out = nullptr;
    napi_get_boolean(env, v, &out);
    return out;
}

bool ReadInt(napi_env env, napi_value v, int32_t *out) {
    if (v == nullptr) {
        return false;
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, v, &type) != napi_ok || type != napi_number) {
        return false;
    }
    return napi_get_value_int32(env, v, out) == napi_ok;
}

std::string SafeString(const char *s) {
    return s == nullptr ? std::string() : std::string(s);
}

} // namespace

// ---------------------------------------------------------------- 导出函数

namespace {

/**
 * probeFd(fd) —— 只读地描述这个 fd 对应的设备，不改变任何状态。
 *
 * 这是整条移植链路的试金石：能拿到描述符，说明 OHOS 的 usbManager 给出的
 * fd 确实是 usbfs 的 fd，libusb 的 linux_usbfs 后端可以正常工作。
 */
napi_value ProbeFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1;
    if (!ReadInt(env, argc > 0 ? args[0] : nullptr, &fd) || fd < 0) {
        return MakeString(env, "参数无效：需要非负 fd");
    }

    try {
        libusb_device_handle *handle = nullptr;
        int err = libusb_wrap_sys_device(nullptr, static_cast<intptr_t>(fd), &handle);
        if (err < 0 || handle == nullptr) {
            char buf[256];
            snprintf(buf, sizeof(buf), "wrap 失败(%d): %s", err,
                     libusb_strerror(static_cast<enum libusb_error>(err)));
            return MakeString(env, buf);
        }

        libusb_device *dev = libusb_get_device(handle);
        libusb_device_descriptor desc{};
        std::string detail;
        if (dev == nullptr) {
            detail = "libusb_get_device 返回空";
        } else if (libusb_get_device_descriptor(dev, &desc) < 0) {
            detail = "取设备描述符失败";
        } else {
            char buf[512];
            char manu[128] = {0};
            char prod[128] = {0};
            if (desc.iManufacturer != 0) {
                libusb_get_string_descriptor_ascii(handle, desc.iManufacturer,
                                                   reinterpret_cast<unsigned char *>(manu), sizeof(manu) - 1);
            }
            if (desc.iProduct != 0) {
                libusb_get_string_descriptor_ascii(handle, desc.iProduct,
                                                   reinterpret_cast<unsigned char *>(prod), sizeof(prod) - 1);
            }
            snprintf(buf, sizeof(buf),
                     "vid=0x%04x pid=0x%04x class=0x%02x cfg=%u bus=%d addr=%d speed=%d busid=%s %s %s",
                     desc.idVendor, desc.idProduct, desc.bDeviceClass, desc.bNumConfigurations,
                     libusb_get_bus_number(dev), libusb_get_device_address(dev),
                     static_cast<int>(libusb_get_device_speed(dev)),
                     usbipdcpp::get_device_busid(dev).c_str(), manu, prod);
            detail = buf;
        }
        // 已置 fd_keep：close 不会关闭 ArkTS 侧持有的原 fd
        libusb_close(handle);
        return MakeString(env, detail);
    } catch (const std::exception &e) {
        LOGE("probeFd threw: %{public}s", e.what());
        return MakeString(env, std::string("异常: ") + e.what());
    } catch (...) {
        return MakeString(env, "未知异常");
    }
}

/** init() —— 幂等初始化 libusb */
napi_value InitNative(napi_env env, napi_callback_info /*info*/) {
    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        AttachLogger();
        return MakeBool(env, EnsureLibusbLocked());
    } catch (const std::exception &e) {
        LOGE("init threw: %{public}s", e.what());
        return MakeBool(env, false);
    } catch (...) {
        return MakeBool(env, false);
    }
}

/** bindDevice(fd) —— 用 fd 绑定设备，成功返回 0；busid 用 getLastBusid() 取 */
napi_value BindDevice(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1;
    if (!ReadInt(env, argc > 0 ? args[0] : nullptr, &fd) || fd < 0) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }

    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!EnsureLibusbLocked()) {
            return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
        }
        if (!g_server) {
            return MakeInt(env, ErrorCode::SERVER_NOT_RUNNING);
        }
        spdlog::info("绑定设备 fd={}", fd);

        // 先取 busid 再绑定：取不到就直接返回，不留"绑上了却报不出 busid"的半成品
        std::string busid;
        {
            libusb_device_handle *tmp = nullptr;
            int err = libusb_wrap_sys_device(nullptr, static_cast<intptr_t>(fd), &tmp);
            if (err < 0 || tmp == nullptr) {
                spdlog::error("临时 wrap 失败: {}", libusb_strerror(static_cast<enum libusb_error>(err)));
                return MakeInt(env, ErrorCode::DEVICE_OPEN_FAILED);
            }
            libusb_device *dev = libusb_get_device(tmp);
            if (dev != nullptr) {
                busid = usbipdcpp::get_device_busid(dev);
            }
            libusb_close(tmp);
        }
        if (busid.empty()) {
            spdlog::error("取 busid 失败");
            return MakeInt(env, ErrorCode::DEVICE_NOT_FOUND);
        }

        auto result = g_server->bind_host_device_with_wrapped_fd(static_cast<intptr_t>(fd));
        int code = ToErrorCode(result);

        // 幂等化：同一个 busid 上如果还挂着上一次导出的记录，服务端会拒绝
        // （AlreadyBound=7 / InUse=2），而界面上表现成「这台设备怎么都打不开」。
        //
        // 这个残留是必然会出现的：ArkTS 侧每次绑定都会 closeDevice 后重新
        // connectDevice，fd 每次都不一样，但 libusb 认的 busid（端口路径）不变；
        // 只要有一次解绑没走完（设备正在被客户端使用、或拔插发生在两次轮询之间），
        // 旧记录就留在 available/using 里，下一次绑定必然撞 busid。
        //
        // 处理办法是"替换"而不是"拒绝"：先按 busid 把旧记录摘掉，再重绑一次。
        // using 状态下 notify_device_removed 是异步踢会话（trigger_session_stop），
        // 会话收尾后才把设备从 using 移除，所以这里留最多 ~600ms 给收尾。
        if (code == ErrorCode::DEVICE_ALREADY_BOUND || code == ErrorCode::DEVICE_IN_USE) {
            spdlog::warn("busid={} 已有残留记录(code={})，摘除后重试", busid, code);
            g_server->notify_device_removed(busid);
            for (int i = 0; i < 24; ++i) {
                std::this_thread::sleep_for(std::chrono::milliseconds(25));
                code = ToErrorCode(g_server->bind_host_device_with_wrapped_fd(static_cast<intptr_t>(fd)));
                if (code == ErrorCode::SUCCESS) {
                    spdlog::info("清除残留后重试绑定成功 busid={} (第{}次)", busid, i + 1);
                    break;
                }
                if (code != ErrorCode::DEVICE_ALREADY_BOUND && code != ErrorCode::DEVICE_IN_USE) {
                    break;
                }
            }
        }

        if (code == ErrorCode::SUCCESS) {
            g_last_busid = busid;
            spdlog::info("绑定成功 busid={}", busid);
        } else {
            spdlog::error("绑定失败 busid={} code={}", busid, code);
        }
        return MakeInt(env, code);
    } catch (const std::exception &e) {
        LOGE("bindDevice threw: %{public}s", e.what());
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    } catch (...) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
}

/** unbindDevice(fd) */
napi_value UnbindDevice(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t fd = -1;
    if (!ReadInt(env, argc > 0 ? args[0] : nullptr, &fd) || fd < 0) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_server) {
            return MakeInt(env, ErrorCode::SERVER_NOT_RUNNING);
        }
        int code = ToErrorCode(g_server->unbind_host_device_by_fd(static_cast<intptr_t>(fd)));
        if (code == ErrorCode::SUCCESS) {
            g_last_busid.clear();
        }
        return MakeInt(env, code);
    } catch (const std::exception &e) {
        LOGE("unbindDevice threw: %{public}s", e.what());
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    } catch (...) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
}

napi_value GetLastBusid(napi_env env, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return MakeString(env, g_last_busid);
}

/** startServer(port) —— 返回实际监听端口，失败返回 -1 */
napi_value StartServer(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t port = 3240;
    if (!ReadInt(env, argc > 0 ? args[0] : nullptr, &port) || port <= 0 || port > 65535) {
        port = 3240;
    }

    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!EnsureLibusbLocked()) {
            return MakeInt(env, -1);
        }
        if (g_running) {
            return MakeInt(env, g_port);
        }

        // 与 Android 侧一致的宽松策略：UVC 等设备 ISO 提交偶发 IO 错误时，
        // 只让本次 URB 以 EPIPE 结束，而不是把整台设备从客户端踢掉
        usbipdcpp::LibusbServerConfig config;
        config.device_handler_config.submit_error_policy =
                usbipdcpp::LibusbSubmitErrorPolicy::DisconnectOnDeviceGone;

        g_server = std::make_unique<usbipdcpp::LibusbServer>(config);
        // 关闭热插拔：OHOS 侧由 ArkTS 订阅 USB 插拔事件后显式调 bind/unbind，
        // 不依赖 libusb 自己枚举（沙箱里既没有 udev 也没有 /dev 枚举权限）
        g_server->set_hotplug_enabled(false);

        asio::ip::tcp::endpoint endpoint(asio::ip::tcp::v4(), static_cast<unsigned short>(port));
        auto ec = g_server->start(endpoint);
        if (ec) {
            spdlog::error("启动失败: {}", ec.message());
            g_server.reset();
            return MakeInt(env, -1);
        }
        g_running = true;
        g_port = g_server->get_server().endpoint().port();
        spdlog::info("服务已启动，监听端口 {}", g_port);
        return MakeInt(env, g_port);
    } catch (const std::exception &e) {
        LOGE("startServer threw: %{public}s", e.what());
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_server) {
            try {
                g_server->stop();
            } catch (...) {
            }
            g_server.reset();
        }
        g_running = false;
        return MakeInt(env, -1);
    } catch (...) {
        return MakeInt(env, -1);
    }
}

napi_value StopServer(napi_env env, napi_callback_info /*info*/) {
    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (g_server) {
            g_server->stop();
            g_server.reset();
        }
        g_running = false;
        spdlog::info("服务已停止");
    } catch (const std::exception &e) {
        LOGE("stopServer threw: %{public}s", e.what());
    } catch (...) {
    }
    return MakeBool(env, true);
}

napi_value IsRunning(napi_env env, napi_callback_info /*info*/) {
    std::lock_guard<std::mutex> lock(g_mutex);
    return MakeBool(env, g_running);
}

/**
 * getBoundBusids() —— 服务端当前导出的全部 busid，用 '|' 分隔。
 *
 * 存在的意义：界面的「已共享」状态不能靠 ArkTS 自己记账。地址会被复用、
 * 页面会被重建，只要有一次继承漏掉，开关就会显示成"关闭"而服务端其实还
 * 导出着，用户再点一次就必然撞 busid。所以状态唯一真相放在这里，界面每帧
 * 拉一次即可。
 *
 * busid 形如 `1-2:0`，前缀 `1-2` 正好等于 usbManager 给出的设备 name，
 * 因此 ArkTS 侧用 `busid === name || busid.startsWith(name + ':')` 就能对上。
 */
napi_value GetBoundBusids(napi_env env, napi_callback_info /*info*/) {
    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_server) {
            return MakeString(env, "");
        }
        std::string out;
        auto &srv = g_server->get_server();
        std::shared_lock<std::shared_mutex> devices_lock(srv.get_devices_mutex());
        for (const auto &dev: srv.get_available_devices()) {
            if (!out.empty()) {
                out.push_back('|');
            }
            out += dev->busid;
        }
        for (const auto &entry: srv.get_using_devices()) {
            if (!out.empty()) {
                out.push_back('|');
            }
            out += entry.first;
        }
        return MakeString(env, out);
    } catch (const std::exception &e) {
        LOGE("getBoundBusids threw: %{public}s", e.what());
        return MakeString(env, "");
    } catch (...) {
        return MakeString(env, "");
    }
}

/** setLogCallback(cb) —— 注册/清空日志回调 */
napi_value SetLogCallback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value name = nullptr;
    napi_create_string_utf8(env, "UsbIpLog", NAPI_AUTO_LENGTH, &name);

    napi_threadsafe_function old = g_log_tsfn;
    g_log_tsfn = nullptr;
    if (old != nullptr) {
        napi_release_threadsafe_function(old, napi_tsfn_release);
    }

    if (argc == 0 || args[0] == nullptr) {
        return MakeBool(env, true);
    }
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, args[0], &type) != napi_ok || type != napi_function) {
        return MakeBool(env, false);
    }
    napi_threadsafe_function tsfn = nullptr;
    napi_status status = napi_create_threadsafe_function(
            env, args[0], nullptr, name,
            0, 1, nullptr, nullptr, nullptr, CallJsLog, &tsfn);
    if (status != napi_ok) {
        LOGE("create_threadsafe_function failed: %{public}d", static_cast<int>(status));
        return MakeBool(env, false);
    }
    // 不因日志回调把事件循环吊住
    napi_unref_threadsafe_function(env, tsfn);
    g_log_tsfn = tsfn;
    return MakeBool(env, true);
}

/**
 * notifyDeviceRemoved(busid) —— 物理拔出时告诉服务端该设备已不存在。
 *
 * 走 server 的设备移除通道而不是 unbind_by_fd：拔线后 fd 已失效，按 fd 查
 * 可能查不到；按 busid 移除能保证客户端收到断开、服务端列表也清干净。
 */
napi_value NotifyDeviceRemoved(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    size_t len = 0;
    if (argc == 0 || args[0] == nullptr ||
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len) != napi_ok || len == 0) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
    std::string busid(len, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, args[0], busid.data(), len + 1, &copied) != napi_ok) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
    busid.resize(copied);

    try {
        std::lock_guard<std::mutex> lock(g_mutex);
        if (!g_server) {
            return MakeInt(env, ErrorCode::SERVER_NOT_RUNNING);
        }
        spdlog::info("设备已拔出 busid={}", busid);
        int code = ToErrorCode(g_server->notify_device_removed(busid));
        if (g_last_busid == busid) {
            g_last_busid.clear();
        }
        return MakeInt(env, code);
    } catch (const std::exception &e) {
        LOGE("notifyDeviceRemoved threw: %{public}s", e.what());
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    } catch (...) {
        return MakeInt(env, ErrorCode::UNKNOWN_ERROR);
    }
}

/** setLogLevel(level) —— 0 trace / 1 debug / 2 info / 3 warn / 4 error / 5 critical */
napi_value SetLogLevel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t level = 2;
    if (!ReadInt(env, argc > 0 ? args[0] : nullptr, &level)) {
        return MakeBool(env, false);
    }
    if (level < 0) {
        level = 0;
    }
    if (level > 5) {
        level = 5;
    }
    auto logger = spdlog::default_logger();
    if (logger == nullptr) {
        return MakeBool(env, false);
    }
    logger->set_level(static_cast<spdlog::level::level_enum>(level));
    // debug/trace 只影响 hilog，不上 UI（JsLogSink 已过滤），可以放心打开
    LOGI("spdlog level set to %{public}d", level);
    return MakeBool(env, true);
}

} // namespace

// ---------------------------------------------------------------- 模块注册

namespace {

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
            {"init", nullptr, InitNative, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"probeFd", nullptr, ProbeFd, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"bindDevice", nullptr, BindDevice, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"unbindDevice", nullptr, UnbindDevice, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"notifyDeviceRemoved", nullptr, NotifyDeviceRemoved, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getLastBusid", nullptr, GetLastBusid, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"startServer", nullptr, StartServer, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"stopServer", nullptr, StopServer, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"isRunning", nullptr, IsRunning, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"getBoundBusids", nullptr, GetBoundBusids, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setLogCallback", nullptr, SetLogCallback, nullptr, nullptr, nullptr, napi_default, nullptr},
            {"setLogLevel", nullptr, SetLogLevel, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    LOGI("usbip_napi 已注册");
    return exports;
}

napi_module g_module = {
        .nm_version = 1,
        .nm_flags = 0,
        .nm_filename = nullptr,
        .nm_register_func = Init,
        .nm_modname = "usbip_napi",
        .nm_priv = nullptr,
        .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterUsbIpModule(void) {
    napi_module_register(&g_module);
}
