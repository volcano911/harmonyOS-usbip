/**
 * USB/IP 共享 —— 鸿蒙原生版主页面
 *
 * 视觉走 iOS grouped list 风格：浅灰底 + 纯白卡片 + 0.5px 细线 + 单一强调蓝。
 * 交互语义与 Android 原版（Jetpack Compose）一致，数据来源见 UsbDeviceService。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { SharedDevice, UsbDeviceService } from '../usbip/UsbDeviceService';
import { keepAlive, KeepAliveState } from '../usbip/KeepAlive';
import { DeviceMemory } from '../usbip/DeviceMemory';
import { UsbWatcher } from '../usbip/UsbWatcher';
import usbipNative from 'libusbip_napi.so';

const DOMAIN = 0x3200;
const TAG = 'UsbIpUi';
const MAX_LOG_LINES: number = 300;

/** iOS 系统色板，全页只用这几个 */
const C_BG = '#F2F2F7';
const C_CARD = '#FFFFFF';
const C_LABEL = '#000000';
const C_LABEL2 = '#8E8E93';
const C_LABEL3 = '#C7C7CC';
const C_LINE = '#E5E5EA';
const C_FILL = '#F2F2F7';
const C_BLUE = '#007AFF';
const C_GREEN = '#34C759';
const C_GREEN_TEXT = '#248A3D';
const C_GREEN_BG = '#E9F9EE';
const C_RED_TEXT = '#D70015';
const C_RED_BG = '#FFECEB';
const C_ORANGE = '#FF9500';
/** 白底日志用深一档的语义色，保证可读 */
const L_NORMAL = '#3C3C43';
const L_INFO = '#0071E3';
const L_OK = '#248A3D';
const L_WARN = '#B25000';
const L_ERROR = '#D70015';

/** 日志级别 */
const LOG_NORMAL = 0;
const LOG_INFO = 1;
const LOG_OK = 2;
const LOG_WARN = 3;
const LOG_ERROR = 4;

class LogLine {
  id: number;
  time: string;
  text: string;
  kind: number;

  constructor(id: number, time: string, text: string, kind: number) {
    this.id = id;
    this.time = time;
    this.text = text;
    this.kind = kind;
  }
}

@Entry
@Component
struct Index {
  @State devices: SharedDevice[] = [];
  @State logs: LogLine[] = [];
  @State running: boolean = false;
  @State portText: string = '3240';
  @State probeResult: string = '';
  @State busy: boolean = false;
  @State keepAliveText: string = '未申请';
  @State keepAliveActive: boolean = false;

  private service: UsbDeviceService = new UsbDeviceService();
  private logScroller: Scroller = new Scroller();
  private seq: number = 0;
  /** 记住「插上就自动共享」的设备 */
  private memory: DeviceMemory = new DeviceMemory();
  private watcher: UsbWatcher | null = null;
  /** 待刷入的日志行；高频日志按 120ms 合并一次，避免每条都触发整页重排 */
  private pendingLogs: LogLine[] = [];
  private flushTimer: number = -1;
  /** 自动共享是否正在跑，防止 tick 与插入回调重入 */
  private autoRunning: boolean = false;
  /** 自动共享的尝试记录：key = identity@name，同一台设备同一地址只试一次 */
  private autoTried: Map<string, number> = new Map();

  aboutToAppear(): void {
    const ok: boolean = usbipNative.init();
    this.appendLog(ok ? '[native] libusb 初始化成功' : '[native] libusb 初始化失败',
      ok ? LOG_INFO : LOG_ERROR);
    usbipNative.setLogCallback((line: string) => {
      this.appendLog(line);
    });
    keepAlive.onStateChange((state: KeepAliveState) => {
      this.keepAliveActive = state.active;
      this.keepAliveText = state.detail;
      this.appendLog(`[保活] ${state.detail}`, state.active ? LOG_OK : LOG_WARN);
    });
    this.refreshDevices();
    this.initAutoShare();
  }

  aboutToDisappear(): void {
    usbipNative.setLogCallback(undefined);
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    if (this.watcher !== null) {
      this.watcher.stop();
      this.watcher = null;
    }
  }

  // ---------------- 自动识别 / 自动共享 ----------------

  /** 加载记忆名册 + 启动插拔监听 */
  private async initAutoShare(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await this.memory.init(ctx);
      const watcher: UsbWatcher = new UsbWatcher((): SharedDevice[] => this.service.list());
      watcher.onAttached = (device: SharedDevice): void => {
        this.handleAttached(device);
      };
      watcher.onDetached = (name: string, identity: string): void => {
        this.handleDetached(name, identity);
      };
      watcher.onListChanged = (): void => {
        this.refreshDevices();
        // 列表一变就试着补自动共享：不依赖「插入事件」是否被捕捉到
        this.tryAutoShare();
      };
      this.watcher = watcher;
      await watcher.start(2000);
      this.appendLog(`[监听] ${watcher.isEventDriven() ? '插拔事件' : '轮询 2s'} 已开启`
        + ` · 记住 ${this.memory.count()} 台设备`, LOG_INFO);
      await this.tryAutoShare();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'initAutoShare failed: %{public}s', JSON.stringify(err));
    }
  }

  private async handleAttached(device: SharedDevice): Promise<void> {
    try {
      this.refreshDevices();
      const entry: SharedDevice | null = this.findDevice(device.name);
      if (entry !== null) {
        this.appendLog(`[插入] ${entry.label()}`, LOG_INFO);
      }
      // 真正的判断交给 tryAutoShare：即使这里没认出「插入」，下一轮 tick 也会补上
      await this.tryAutoShare();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'handleAttached failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 自动共享（状态驱动，不依赖插入事件）。
   *
   * 之前只靠 onAttached 触发，有个硬伤：拔插发生在两次轮询之间时（<2s），
   * Watcher 认为设备从没离开过，压根不会回调；加上 usbfs 地址会被复用，
   * openDevice() 还可能命中已失效的旧 fd，表现就是「自动绑定毫无反应」。
   * 现在改成：只要名册里的设备出现在列表中且未共享，就尝试一次。
   */
  private async tryAutoShare(): Promise<void> {
    if (this.autoRunning || this.memory.count() === 0) {
      return;
    }
    this.autoRunning = true;
    try {
      const list: SharedDevice[] = this.devices;
      for (let i = 0; i < list.length; i++) {
        const d: SharedDevice = list[i];
        if (d.shared) {
          continue;
        }
        if (!this.memory.has(d)) {
          continue;
        }
        const attempt: string = `${d.identity()}@${d.name}`;
        if (this.autoTried.has(attempt)) {
          continue;
        }
        this.autoTried.set(attempt, 1);
        this.appendLog(`[自动] 命中名册 ${d.identity()}，尝试共享 ${d.label()}`, LOG_INFO);

        if (!this.running) {
          await this.startServer();
          if (!this.running) {
            this.appendLog('[自动] 服务起不来，跳过', LOG_ERROR);
            return;
          }
        }
        // 不在这里 closeDevice：shareDevice 内部要先判断服务端是否已经导出着，
        // 先关 fd 会把"已共享"这条最优路径毁掉，反而制造出 busid 残留。
        const ok: boolean = await this.shareDevice(d, false);
        this.appendLog(ok ? `[自动] ${d.label()} 已共享` : `[自动] ${d.label()} 失败，可手动打开`,
          ok ? LOG_OK : LOG_ERROR);
      }
    } finally {
      this.autoRunning = false;
    }
  }

  private async handleDetached(name: string, identity: string): Promise<void> {
    try {
      const entry: SharedDevice | null = this.findDevice(name);
      // 列表可能已经刷新过（设备已不在 this.devices 里），再按 name 前缀从
      // 服务端导出列表兜一次，否则拔线时通知不到服务端，记录会永远留着
      let busid: string = entry !== null ? entry.busid : '';
      if (busid.length === 0) {
        busid = this.busidOf(name, this.boundBusids());
      }
      const wasShared: boolean = busid.length > 0;
      if (wasShared) {
        const code: number = usbipNative.notifyDeviceRemoved(busid);
        this.appendLog(`[拔出] ${name} · 已通知服务端(code=${code}, busid=${busid})`, LOG_WARN);
      } else {
        this.appendLog(`[拔出] ${name}`, LOG_WARN);
      }
      this.service.closeDevice(name);
      // 地址会被复用：清掉这台设备的尝试记录，重插后允许再试一次
      this.clearAutoTried(name);
      this.refreshDevices();
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'handleDetached failed: %{public}s', JSON.stringify(err));
    }
  }

  private clearAutoTried(name: string): void {
    const gone: string[] = [];
    this.autoTried.forEach((_v: number, key: string) => {
      if (key.lastIndexOf(`@${name}`) >= 0) {
        gone.push(key);
      }
    });
    for (let i = 0; i < gone.length; i++) {
      this.autoTried.delete(gone[i]);
    }
  }

  private findDevice(name: string): SharedDevice | null {
    for (let i = 0; i < this.devices.length; i++) {
      if (this.devices[i].name === name) {
        return this.devices[i];
      }
    }
    return null;
  }

  /**
   * 从服务端导出的 busid 集合里取出这台设备对应的那一项，没有返回空串。
   *
   * busid 形如 `1-2:0`，冒号前是端口路径，正好等于 usbManager 给的 name（`1-2`）。
   * 界面判断"是否已共享"只认这个结果，不靠自己记账 —— 记账一旦漏一次，
   * 开关就会显示成关闭而服务端其实还导出着，用户再点一下必然撞 busid。
   */
  private busidOf(name: string, bound: string): string {
    if (bound.length === 0) {
      return '';
    }
    const parts: string[] = bound.split('|');
    const prefix: string = `${name}:`;
    for (let i = 0; i < parts.length; i++) {
      const b: string = parts[i];
      if (b === name || b.indexOf(prefix) === 0) {
        return b;
      }
    }
    return '';
  }

  private boundBusids(): string {
    try {
      return usbipNative.getBoundBusids();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getBoundBusids failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  // ---------------- 数据 ----------------

  private stamp(): string {
    const d: Date = new Date();
    const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    const ss: string = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
    return `${hh}:${mm}:${ss}`;
  }

  private classify(line: string): number {
    const l: string = line.toLowerCase();
    if (l.indexOf('失败') >= 0 || l.indexOf('error') >= 0 || l.indexOf('fail') >= 0
      || l.indexOf('拒绝') >= 0) {
      return LOG_ERROR;
    }
    if (l.indexOf('警告') >= 0 || l.indexOf('warn') >= 0 || l.indexOf('超时') >= 0) {
      return LOG_WARN;
    }
    if (l.indexOf('成功') >= 0 || l.indexOf('已生效') >= 0 || l.indexOf('ok') >= 0) {
      return LOG_OK;
    }
    if (l.indexOf('[native]') >= 0 || l.indexOf('[probe]') >= 0) {
      return LOG_INFO;
    }
    return LOG_NORMAL;
  }

  private appendLog(line: string, kind: number = -1): void {
    const k: number = kind >= 0 ? kind : this.classify(line);
    this.pendingLogs.push(new LogLine(this.seq++, this.stamp(), line, k));
    if (this.flushTimer !== -1) {
      return;
    }
    this.flushTimer = setTimeout(() => {
      this.flushTimer = -1;
      this.flushLogs();
    }, 120);
  }

  /** 把攒下的日志一次性并进 @State，减少重排次数 */
  private flushLogs(): void {
    if (this.pendingLogs.length === 0) {
      return;
    }
    const next: LogLine[] = this.logs.concat(this.pendingLogs);
    this.pendingLogs = [];
    while (next.length > MAX_LOG_LINES) {
      next.shift();
    }
    this.logs = next;
    try {
      this.logScroller.scrollEdge(Edge.Bottom);
    } catch (e) {
      // 列表尚未挂载时忽略
    }
  }

  /**
   * 刷新设备列表。
   *
   * 「是否已共享」以服务端为准（getBoundBusids），不再靠按 name 继承上一帧的
   * shared 标记：name 在拔插后会变、列表对象每帧都是新建的，任何一次继承漏掉
   * 都会让开关显示成关闭，用户再点一次就撞 busid 报错。fd 仅用于展示，继承即可。
   */
  private refreshDevices(): void {
    const list: SharedDevice[] = this.service.list();
    const bound: string = this.boundBusids();
    const prev: SharedDevice[] = this.devices;
    for (let i = 0; i < list.length; i++) {
      const busid: string = this.busidOf(list[i].name, bound);
      list[i].busid = busid;
      list[i].shared = busid.length > 0;
      for (let j = 0; j < prev.length; j++) {
        if (prev[j].name === list[i].name) {
          list[i].fd = prev[j].fd;
          break;
        }
      }
      if (!list[i].shared) {
        list[i].fd = -1;
      }
    }
    this.devices = list;
  }

  // ---------------- 动作 ----------------

  private async startServer(): Promise<void> {
    const port: number = Number.parseInt(this.portText, 10);
    if (Number.isNaN(port) || port <= 0 || port > 65535) {
      promptAction.showToast({ message: '端口不合法' });
      return;
    }
    this.busy = true;
    const actual: number = usbipNative.startServer(port);
    this.busy = false;
    if (actual > 0) {
      this.running = true;
      this.portText = actual.toString();
      this.appendLog(`[服务] 已监听 0.0.0.0:${actual}`, LOG_OK);
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const kept: boolean = await keepAlive.start(ctx);
      promptAction.showToast({
        message: kept
          ? `已启动，端口 ${actual}，后台保活已开启`
          : `已启动，端口 ${actual}；保活未生效，切后台可能被冻结`
      });
    } else {
      this.appendLog('[服务] 启动失败（端口被占用？）', LOG_ERROR);
      promptAction.showToast({ message: '启动失败，看日志' });
    }
  }

  private async stopServer(): Promise<void> {
    this.busy = true;
    usbipNative.stopServer();
    this.service.closeAll();
    for (let i = 0; i < this.devices.length; i++) {
      this.devices[i].shared = false;
      this.devices[i].fd = -1;
      this.devices[i].busid = '';
    }
    this.devices = this.devices.slice();
    this.running = false;
    this.appendLog('[服务] 已停止', LOG_WARN);
    await keepAlive.stop();
    this.busy = false;
  }

  /** 开关入口：按目标状态分发（ArkUI 的 onChange 在失败时需要回弹） */
  private async setShared(device: SharedDevice, wantOn: boolean): Promise<void> {
    if (!this.running) {
      promptAction.showToast({ message: '请先启动服务' });
      this.devices = this.devices.slice();
      return;
    }
    if (wantOn === device.shared) {
      return;
    }
    if (wantOn) {
      await this.shareDevice(device, true);
    } else {
      await this.unshareDevice(device, true);
    }
  }

  /**
   * 打开并绑定一台设备（幂等）。
   * @param remember 是否把它记进「下次插上自动共享」的名册（自动共享时为 false）
   */
  private async shareDevice(device: SharedDevice, remember: boolean): Promise<boolean> {
    this.busy = true;
    try {
      // ---- 幂等第一层：服务端已经导出着，且我们手上还有个活着的 fd ----
      // 此时不能再 closeDevice + openDevice：换来的新 fd 和 busid 会和旧记录
      // 撞（服务端按 busid 查重直接拒绝），而旧记录里的 fd 已经被我们关掉，
      // 客户端一连就断。最优做法是什么都不做。
      let bound: string = this.busidOf(device.name, this.boundBusids());
      if (bound.length > 0 && device.fd >= 0) {
        device.shared = true;
        device.busid = bound;
        this.appendLog(`[绑定] ${device.name} 已在共享中（busid=${bound}），跳过`, LOG_INFO);
        if (remember) {
          await this.memory.remember(device);
        }
        this.devices = this.devices.slice();
        return true;
      }

      // ---- 幂等第二层：服务端有记录但我们的 fd 已经没了 ----
      // 典型场景是拔插后旧 fd 失效、或这一轮轮询没枚举到设备。旧记录必须先
      // 按 busid 摘掉，否则新绑一定被 AlreadyBound/InUse 挡回来。
      if (bound.length > 0) {
        this.appendLog(`[绑定] ${device.name} 服务端残留 busid=${bound}，先摘除`, LOG_WARN);
        usbipNative.notifyDeviceRemoved(bound);
      }

      // 每次绑定都重新走一遍 requestRight → connectDevice → getFileDescriptor。
      // 复用缓存句柄在「拔插过一次、地址又被系统复用」时会拿到失效 fd。
      this.service.closeDevice(device.name);
      device.fd = -1;
      const fd: number = await this.service.openDevice(device.name);
      if (fd < 0) {
        this.appendLog(`[打开] ${device.name} 失败（授权被拒或系统占用）`, LOG_ERROR);
        promptAction.showToast({ message: '打开设备失败' });
        this.devices = this.devices.slice();
        return false;
      }
      const code: number = usbipNative.bindDevice(fd);
      if (code !== 0) {
        this.service.closeDevice(device.name);
        this.appendLog(`[绑定] ${device.name} 失败 code=${code}${this.explainBindCode(code)}`, LOG_ERROR);
        promptAction.showToast({ message: `绑定失败 code=${code}` });
        this.devices = this.devices.slice();
        return false;
      }
      device.shared = true;
      device.fd = fd;
      device.busid = usbipNative.getLastBusid();
      this.appendLog(`[绑定] ${device.name} → busid=${device.busid}`, LOG_OK);
      if (remember) {
        await this.memory.remember(device);
      }
      // 放在 remember 之后：列表重建时读到的 memory 才是最新的（"自动"角标）
      this.devices = this.devices.slice();
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'shareDevice failed: %{public}s', JSON.stringify(err));
      return false;
    } finally {
      this.busy = false;
    }
  }

  /** 绑定错误码的人话解释，省得每次还要翻源码 */
  private explainBindCode(code: number): string {
    switch (code) {
      case 1: return '（设备未找到）';
      case 2: return '（设备正在被客户端使用）';
      case 3: return '（打开 fd 失败）';
      case 4: return '（取描述符失败）';
      case 5: return '（取配置失败）';
      case 6: return '（claim 接口失败）';
      case 7: return '（该 busid 已导出）';
      case 8: return '（Hub 被过滤）';
      case 9: return '（服务未启动）';
      default: return '';
    }
  }

  /**
   * 解绑并关闭一台设备；remember=true 表示是用户手动关的，要一并忘掉。
   *
   * 必须按 busid 走「设备移除」通道，不能用 unbindDevice(fd)：
   * 设备正被客户端使用时，unbind_host_device_by_fd 会返回 DeviceInUse 且
   * 什么都不做 —— 界面关了、服务端还导着，这就是下次打不开的直接原因。
   */
  private async unshareDevice(device: SharedDevice, remember: boolean): Promise<void> {
    let busid: string = device.busid;
    if (busid.length === 0) {
      busid = this.busidOf(device.name, this.boundBusids());
    }

    let code: number = -1;
    if (busid.length > 0) {
      code = usbipNative.notifyDeviceRemoved(busid);
    } else if (device.fd >= 0) {
      code = usbipNative.unbindDevice(device.fd);
    }

    this.appendLog(code === 0 ? `[解绑] ${device.name} busid=${busid} 已提交`
      : `[解绑] ${device.name} 失败 code=${code}`, code === 0 ? LOG_OK : LOG_ERROR);
    this.service.closeDevice(device.name);
    device.shared = false;
    device.fd = -1;
    device.busid = '';
    if (remember) {
      await this.memory.forget(device);
      // 手动关掉的设备不要再被自动共享拉起来
      this.clearAutoTried(device.name);
    }
    this.devices = this.devices.slice();

    if (code === 0 && busid.length > 0) {
      // using 状态下踢会话是异步的，等它真的从导出列表消失再收敛 UI，
      // 否则下一轮 refresh 会把开关又弹回"开"
      this.settleUnbind(device, busid, 0);
    }
  }

  /** 解绑后的收敛：每 50ms 查一次服务端，最多 600ms，不阻塞 UI */
  private settleUnbind(device: SharedDevice, busid: string, round: number): void {
    const still: boolean = this.busidOf(device.name, this.boundBusids()).length > 0;
    if (!still) {
      if (round > 0) {
        this.appendLog(`[解绑] ${device.name} 已从导出列表移除`, LOG_OK);
      }
      this.refreshDevices();
      return;
    }
    if (round >= 12) {
      this.appendLog(`[解绑] ${device.name} 仍在导出列表（客户端可能还连着）`, LOG_WARN);
      this.refreshDevices();
      return;
    }
    setTimeout(() => {
      this.settleUnbind(device, busid, round + 1);
    }, 50);
  }

  /**
   * 验证通道：把 ArkTS 拿到的 fd 交给 libusb wrap 一次，读回描述符。
   *
   * 这是整条链路唯一的高风险点（鸿蒙给的到底是不是 usbfs fd）。
   * libusb_wrap_sys_device 内部把 fd 标记为 fd_keep，所以 libusb_close
   * 不会关掉我们持有的原 fd，验证是非破坏性的。
   */
  private async probe(device: SharedDevice): Promise<void> {
    const wasShared: boolean = device.shared;
    const reuse: boolean = wasShared && device.fd >= 0;
    this.busy = true;
    try {
      const fd: number = reuse ? device.fd : await this.service.openDevice(device.name);
      if (fd < 0) {
        this.probeResult = `${device.label()} · 拿不到 fd（未授权或已被系统占用）`;
        this.appendLog('[验证] 拿不到 fd', LOG_ERROR);
        return;
      }
      const result: string = usbipNative.probeFd(fd);
      this.probeResult = result;
      const failed: boolean = result.indexOf('失败') >= 0 || result.indexOf('无效') >= 0;
      this.appendLog(`[验证] ${result}`, failed ? LOG_ERROR : LOG_OK);
      if (failed) {
        promptAction.showToast({ message: '验证失败，看日志' });
      }
      if (!reuse) {
        // 只是验证，不长期占着设备
        this.service.closeDevice(device.name);
        device.fd = -1;
        this.devices = this.devices.slice();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'probe failed: %{public}s', JSON.stringify(err));
    } finally {
      this.busy = false;
    }
  }

  // ---------------- 视觉辅助 ----------------

  private classLabel(clazz: number): string {
    switch (clazz) {
      case 0x01: return '音频';
      case 0x02: return '串口';
      case 0x03: return 'HID';
      case 0x06: return '图像';
      case 0x07: return '打印';
      case 0x08: return '存储';
      case 0x09: return 'Hub';
      case 0x0A: return '网络';
      case 0x0B: return '密钥';
      case 0x0D: return '安全';
      case 0x0E: return '视频';
      case 0xE0: return '无线';
      case 0xFE: return '应用';
      case 0xFF: return '厂商';
      default: return 'USB';
    }
  }

  private hex4(n: number): string {
    const s: string = n.toString(16).toUpperCase();
    return s.length >= 4 ? s : `0000${s}`.slice(-4);
  }

  private deviceSubtitle(device: SharedDevice): string {
    return `${this.hex4(device.vendorId)}:${this.hex4(device.productId)}  ·  ${device.name}`;
  }

  private logColor(kind: number): string {
    switch (kind) {
      case LOG_ERROR: return L_ERROR;
      case LOG_WARN: return L_WARN;
      case LOG_OK: return L_OK;
      case LOG_INFO: return L_INFO;
      default: return L_NORMAL;
    }
  }

  /** 小号字距标签，撑一点科技感 */
  @Builder
  caption(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(C_LABEL2)
      .letterSpacing(1.4)
  }

  @Builder
  hairline() {
    Divider()
      .color(C_LINE)
      .strokeWidth(0.5)
  }

  // ---------------- 标题 ----------------

  @Builder
  header() {
    Row() {
      Column({ space: 2 }) {
        Text('USB/IP')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(C_LABEL)
        Text('设备共享服务')
          .fontSize(13)
          .fontColor(C_LABEL2)
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      Row({ space: 5 }) {
        Circle({ width: 6, height: 6 })
          .fill(this.running ? C_GREEN : C_LABEL3)
        Text(this.running ? '运行中' : '已停止')
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.running ? C_GREEN_TEXT : C_LABEL2)
      }
      .padding({ left: 10, right: 12, top: 6, bottom: 6 })
      .backgroundColor(this.running ? C_GREEN_BG : C_FILL)
      .borderRadius(999)
    }
    .width('100%')
    .alignItems(VerticalAlign.Bottom)
    .padding({ left: 4, right: 4, top: 4 })
  }

  // ---------------- 主控卡 ----------------

  /** 三根递增竖线，运行时点亮 */
  @Builder
  signal() {
    Row({ space: 3 }) {
      Rect({ width: 2.5, height: 6 }).radius(1.5)
        .fill(this.running ? C_BLUE : C_LABEL3)
      Rect({ width: 2.5, height: 11 }).radius(1.5)
        .fill(this.running ? C_BLUE : C_LABEL3)
      Rect({ width: 2.5, height: 16 }).radius(1.5)
        .fill(this.running ? C_BLUE : C_LABEL3)
    }
    .height(18)
    .alignItems(VerticalAlign.Bottom)
    .opacity(this.running ? 1 : 0.6)
  }

  @Builder
  controlCard() {
    Column() {
      // 端口大数字区
      Row() {
        Column({ space: 5 }) {
          this.caption('监听端口')
          Text(this.running ? this.portText : '----')
            .fontSize(40)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.running ? C_LABEL : C_LABEL3)
            .fontFamily('monospace')
          Text(`0.0.0.0:${this.portText}   TCP`)
            .fontSize(11)
            .fontColor(C_LABEL3)
            .fontFamily('monospace')
        }
        .alignItems(HorizontalAlign.Start)
        Blank()
        Column({ space: 6 }) {
          this.signal()
          Text(this.running ? 'LISTEN' : 'IDLE')
            .fontSize(10)
            .fontColor(this.running ? C_BLUE : C_LABEL3)
            .letterSpacing(1.2)
        }
        .alignItems(HorizontalAlign.End)
        .margin({ bottom: 2 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
      .padding({ left: 16, right: 16, top: 16, bottom: 14 })

      this.hairline()

      // 设置项：端口
      Row() {
        Text('端口')
          .fontSize(16)
          .fontColor(C_LABEL)
        Blank()
        TextInput({ text: this.portText })
          .type(InputType.Number)
          .width(110)
          .height(34)
          .padding(0)
          .textAlign(TextAlign.End)
          .fontSize(16)
          .fontColor(this.running ? C_LABEL3 : C_BLUE)
          .backgroundColor(Color.Transparent)
          .enabled(!this.running)
          .onChange((value: string) => {
            this.portText = value;
          })
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })

      this.hairline()

      // 设置项：后台保活
      Row() {
        Text('后台保活')
          .fontSize(16)
          .fontColor(C_LABEL)
        Blank()
        if (this.keepAliveActive) {
          Text('已生效')
            .fontSize(15)
            .fontColor(C_GREEN_TEXT)
        } else {
          Text(this.running ? '未生效' : '随服务启动')
            .fontSize(15)
            .fontColor(this.running ? C_ORANGE : C_LABEL2)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 180 })
        }
      }
      .width('100%')
      .height(52)
      .padding({ left: 16, right: 16 })

      // 保活失败的详细原因，只在出问题时占一行
      if (this.running && !this.keepAliveActive) {
        Text(this.keepAliveText)
          .fontSize(12)
          .fontColor(C_ORANGE)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }

      // 主按钮
      Column() {
        Button() {
          Text(this.busy ? '处理中…' : (this.running ? '停止服务' : '启动服务'))
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.running ? C_RED_TEXT : '#FFFFFF')
        }
        .width('100%')
        .height(50)
        .backgroundColor(this.running ? C_RED_BG : C_BLUE)
        .borderRadius(14)
        .enabled(!this.busy)
        .onClick(() => {
          if (this.running) {
            this.stopServer();
          } else {
            this.startServer();
          }
        })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 16 })
    }
    .width('100%')
    .backgroundColor(C_CARD)
    .borderRadius(18)
  }

  // ---------------- 设备 ----------------

  @Builder
  deviceRow(device: SharedDevice, isLast: boolean) {
    Column() {
      Row({ space: 12 }) {
        // 图标：统一浅灰底，不搞彩色块
        Stack() {
          Column()
            .width(38)
            .height(38)
            .borderRadius(10)
            .backgroundColor(C_FILL)
          Text(this.classLabel(device.clazz))
            .fontSize(10)
            .fontWeight(FontWeight.Medium)
            .fontColor('#3C3C43')
        }
        .width(38)
        .height(38)

        Column({ space: 3 }) {
          Row({ space: 6 }) {
            Text(device.product.length > 0 ? device.product : '未命名设备')
              .fontSize(16)
              .fontColor(C_LABEL)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (this.memory.has(device)) {
              Text('自动')
                .fontSize(10)
                .fontColor(C_GREEN_TEXT)
                .backgroundColor(C_GREEN_BG)
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(4)
            }
          }
          .width('100%')
          Row({ space: 6 }) {
            Text(this.deviceSubtitle(device))
              .fontSize(12)
              .fontColor(C_LABEL2)
              .fontFamily('monospace')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            if (device.fd >= 0) {
              Text(`fd ${device.fd}`)
                .fontSize(10)
                .fontColor(C_LABEL3)
                .fontFamily('monospace')
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('验证')
          .fontSize(12)
          .fontColor(C_BLUE)
          .padding({ left: 8, right: 10, top: 8, bottom: 8 })
          .enabled(!this.busy)
          .onClick(() => {
            this.probe(device);
          })

        Toggle({ type: ToggleType.Switch, isOn: device.shared })
          .selectedColor(C_GREEN)
          .enabled(!this.busy)
          .onChange((isOn: boolean) => {
            if (isOn !== device.shared) {
              this.setShared(device, isOn);
            }
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 13, bottom: 13 })

      if (!isLast) {
        Row() {
          this.hairline()
        }
        .padding({ left: 66 })
      }
    }
    .width('100%')
  }

  @Builder
  deviceSection() {
    Column() {
      Row() {
        this.caption('USB 设备')
        if (this.devices.length > 0) {
          Text(`${this.devices.length}`)
            .fontSize(11)
            .fontColor(C_LABEL2)
            .margin({ left: 6 })
        }
        Blank()
        Text('刷新')
          .fontSize(15)
          .fontColor(C_BLUE)
          .onClick(() => {
            if (this.watcher !== null) {
              this.watcher.rescan();
            }
            this.refreshDevices();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      if (this.devices.length === 0) {
        Column({ space: 8 }) {
          Column()
            .width(40)
            .height(40)
            .borderRadius(12)
            .backgroundColor(C_FILL)
          Text('没有检测到 USB 设备')
            .fontSize(15)
            .fontColor(C_LABEL)
          Text('用 OTG 线接上设备后点「刷新」')
            .fontSize(12)
            .fontColor(C_LABEL2)
        }
        .width('100%')
        .padding({ top: 30, bottom: 30 })
        .backgroundColor(C_CARD)
        .borderRadius(18)
      } else {
        Column() {
          ForEach(this.devices, (device: SharedDevice, index: number) => {
            this.deviceRow(device, index === this.devices.length - 1)
          }, (device: SharedDevice) => device.name)
        }
        .width('100%')
        .backgroundColor(C_CARD)
        .borderRadius(18)
      }
    }
    .width('100%')
  }

  // ---------------- 日志 ----------------

  @Builder
  logSection() {
    Column() {
      Row() {
        this.caption('运行日志')
        Blank()
        Text('清空')
          .fontSize(15)
          .fontColor(C_BLUE)
          .onClick(() => {
            this.logs = [];
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, bottom: 8 })

      List({ space: 4, scroller: this.logScroller }) {
        ForEach(this.logs, (item: LogLine) => {
          ListItem() {
            Row({ space: 8 }) {
              Text(item.time)
                .fontSize(10.5)
                .fontColor(C_LABEL3)
                .fontFamily('monospace')
                .width(52)
              Text(item.text)
                .fontSize(11.5)
                .fontColor(this.logColor(item.kind))
                .fontFamily('monospace')
                .layoutWeight(1)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
          }
        }, (item: LogLine) => item.id.toString())
      }
      .height(220)
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 12 })
      .backgroundColor(C_CARD)
      .borderRadius(18)
      .scrollBar(BarState.Off)
      .nestedScroll({
        scrollForward: NestedScrollMode.SELF_FIRST,
        scrollBackward: NestedScrollMode.SELF_FIRST
      })
    }
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 22 }) {
          this.header()
          this.controlCard()

          // probe 结果
          if (this.probeResult.length > 0) {
            Row({ space: 8 }) {
              Column()
                .width(3)
                .height(16)
                .borderRadius(2)
                .backgroundColor(C_BLUE)
              Text(this.probeResult)
                .fontSize(12)
                .fontColor(C_LABEL)
                .fontFamily('monospace')
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 11, bottom: 11 })
            .backgroundColor(C_CARD)
            .borderRadius(14)
          }

          this.deviceSection()
          this.logSection()

          Text('USB/IP over TCP  ·  libusb + usbipdcpp')
            .fontSize(10)
            .fontColor(C_LABEL3)
            .letterSpacing(0.6)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 2 })
        }
        .padding({ left: 16, right: 16, top: 12, bottom: 28 })
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(C_BG)
  }
}
