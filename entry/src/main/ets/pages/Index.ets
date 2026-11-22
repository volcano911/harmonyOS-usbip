/**
 * USB/IP 共享 —— 鸿蒙原生版主页面
 *
 * 视觉走 iOS grouped list 风格：浅灰底 + 纯白卡片 + 0.5px 细线 + 单一强调蓝。
 * 交互语义与 Android 原版（Jetpack Compose）一致，数据来源见 UsbDeviceService。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { bundleManager } from '@kit.AbilityKit';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { SharedDevice, UsbDeviceService } from '../usbip/UsbDeviceService';
import { keepAlive, KeepAliveState } from '../usbip/KeepAlive';
import { UsbWatcher } from '../usbip/UsbWatcher';
import usbipNative from 'libusbip_napi.so';

const DOMAIN = 0x3200;
const TAG = 'UsbIpUi';
/** 复制日志时要带上尽量完整的过程，300 行在调试期不够用 */
const MAX_LOG_LINES: number = 800;

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
  private watcher: UsbWatcher | null = null;
  /** 待刷入的日志行；高频日志按 120ms 合并一次，避免每条都触发整页重排 */
  private pendingLogs: LogLine[] = [];
  private flushTimer: number = -1;
  /** 上次健康检查的时间戳，用来把 native 探测节流到 3 秒一次 */
  private lastPruneAt: number = 0;
  /** 上次状态快照的时间戳，心跳 15 秒一次，给日志留时间轴 */
  private lastDumpAt: number = 0;
  /** busid → 连续几轮没有对应在线设备（孤儿导出记录去抖） */
  private orphanRounds: Map<string, number> = new Map();
  /**
   * busid → 绑定成功的时刻。
   *
   * 刚绑完的那两秒里，系统枚举经常短暂缺项（connectDevice 会重新枚举），
   * 此时"对不上任何在线设备"是正常现象，不能当成孤儿摘掉。
   */
  private boundAt: Map<string, number> = new Map();
  /** name → 上次开关动作的时间戳；600ms 内不接受第二次操作，见 setShared */
  private lastActionAt: Map<string, number> = new Map();
  /**
   * 设备身份 → 绑定成功时 native 返回的真实 busid。
   *
   * 界面判断"是否已共享"必须用这个地面真相，不能再靠推导：界面算出来的值
   * 和 native 实际用的值只要差一个字符，开关就会在下一帧自动弹回去。
   */
  private boundByIdentity: Map<string, string> = new Map();
  /** stableBusid 的异常只报一次，避免刷屏 */
  private stableWarned: boolean = false;
  /** 版本串缓存，见 buildLabel() */
  private versionText: string = '';

  aboutToAppear(): void {
    // 先把包版本打出来。排查时最怕的情况是"代码改了、装上去的还是旧包"，
    // 有这行就能立刻分辨：日志里的版本号必须和最新构建一致。
    this.appendLog(`[版本] ${this.buildLabel()}`, LOG_INFO);
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
    this.initWatcher();
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

  // ---------------- 插拔监听 ----------------

  /**
   * 启动插拔监听。
   *
   * 只做一件事：把当前接着的设备如实列出来。**不做任何自动共享、
   * 不记"上次用过哪台设备"** —— 每次插入都是独立的一次，用户点了开关才动。
   *
   * 这么定是被现实教育出来的：设备每次重新枚举，busid 里的 device address
   * 都会变（1-2 → 1-4），任何"记住它、下次自动帮我打开"的逻辑都要跟这个变化
   * 赛跑，赛输一次就成了"设备明明在，却报找不到 1-2 然后断开"。宁可多点一次。
   */
  private async initWatcher(): Promise<void> {
    try {
      const watcher: UsbWatcher = new UsbWatcher((): SharedDevice[] => this.service.list());
      watcher.onAttached = (device: SharedDevice): void => {
        this.handleAttached(device);
      };
      watcher.onDetached = (device: SharedDevice): void => {
        this.handleDetached(device);
      };
      // 列表一变只重建界面，不主动去绑任何设备
      watcher.onListChanged = (): void => {
        this.refreshDevices();
      };
      watcher.onTick = (): void => {
        // 与设备列表无关的两项检查：
        //   1) 服务端导出记录的 fd 是否还活着（拔线漏报 → 幽灵 busid）
        //   2) 导出记录里是否存在"当前枚举里根本没有的设备"（地址变了/换了口）
        // 两者只要漏一次，客户端 devlist 里就会多出一个死 busid，
        // 选中它必然得到「找不到busid为X的设备」并断开。
        let changed: boolean = false;
        if (this.pruneGhosts()) {
          changed = true;
        }
        if (this.reapOrphans()) {
          changed = true;
        }
        // 无论有没有清理动作都要重建列表。开关的"已共享"完全由服务端导出列表
        // 决定，只在变化时刷新会让界面长期停在旧状态 —— 曾经出现过服务端正占用
        // 着设备、界面却显示未共享，用户点开关必然撞"设备忙"。
        this.refreshDevices();
        if (changed) {
          this.appendLog('[状态] 设备列表已刷新（服务端导出有变化）', LOG_INFO);
        }
        this.heartbeatDump();
      };
      this.watcher = watcher;
      await watcher.start(2000);
      this.appendLog(`[监听] ${watcher.isEventDriven() ? '插拔事件' : '轮询 2s'} 已开启`, LOG_INFO);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'initWatcher failed: %{public}s', JSON.stringify(err));
    }
  }

  private handleAttached(device: SharedDevice): void {
    try {
      this.refreshDevices();
      const entry: SharedDevice | null = this.findDevice(device.name);
      const d: SharedDevice = entry !== null ? entry : device;
      // name 是 USB 服务给的名字（可能形如 /dev/bus/usb/001/002），busNum/devAddress
      // 才是 busid 的来源。两个都打出来，才能一眼看出「界面以为的 1-2」和
      // 「服务端的 1-2:0」是不是同一台。
      this.appendLog(`[插入] ${d.label()} name=${d.name} bus=${d.busNum}-${d.devAddress}`
        + ` addr=${d.devAddress} sn=${d.serial.length > 0 ? d.serial : '-'}`, LOG_INFO);
      this.logState('插入后');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'handleAttached failed: %{public}s', JSON.stringify(err));
    }
  }

  /**
   * 设备消失。
   *
   * 关键点：这里拿到的是 UsbWatcher 保存的**上一轮快照**。设备已经从
   * getDevices() 里消失，如果只用 name 去 this.devices 里找，多半找不到，
   * 于是"通知服务端移除"这一步会被跳过 —— 服务端就永久留着一个已经不存在的
   * busid。所以先用快照里的 busNum-devAddress 反推 busid，实在不行再用 name 兜。
   */
  private async handleDetached(device: SharedDevice): Promise<void> {
    try {
      const name: string = device.name;
      const bound: string = this.boundBusids();
      const entry: SharedDevice | null = this.findDevice(name);
      let busid: string = entry !== null && entry.busid.length > 0 ? entry.busid : '';
      if (busid.length === 0) {
        busid = this.busidOf(device, bound);
      }
      if (busid.length === 0) {
        busid = this.busidByName(name, bound);
      }
      this.appendLog(`[拔出] ${device.label()} name=${name} bus=${device.busNum}-${device.devAddress}`
        + ` 导出列表=${bound.length > 0 ? bound : '空'}`, LOG_WARN);
      if (busid.length > 0) {
        const code: number = usbipNative.notifyDeviceRemoved(busid);
        this.appendLog(`[拔出] 已通知服务端移除 ${busid} code=${code}`, code === 0 ? LOG_OK : LOG_WARN);
      } else {
        this.appendLog('[拔出] 该设备没有对应的导出记录，无需通知', LOG_INFO);
      }
      this.service.closeDevice(name);
      this.refreshDevices();
      if (busid.length > 0) {
        this.logState('拔出后');
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'handleDetached failed: %{public}s', JSON.stringify(err));
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
   * 取当前列表里同一台设备的最新对象。
   *
   * ArkUI 的 ForEach 按 key 复用子组件，闭包捕获的 device 可能是上一帧的对象；
   * refreshDevices() 每 2 秒换一批新对象，往旧对象上写 shared/fd 不会反映到
   * 列表里，还会让后续判断基于过期数据。所有交互入口都先走这里。
   */
  private liveOf(device: SharedDevice): SharedDevice {
    const live: SharedDevice | null = this.findDevice(device.name);
    return live !== null ? live : device;
  }

  /**
   * 从服务端导出的 busid 集合里取出这台设备对应的那一项，没有返回空串。
   *
   * busid 由 libusb 生成，本机（拿不到 sysfs 拓扑）走的是 `总线-设备地址:端口`
   * 这条分支，形如 `1-2:0`；其中 `2` 是 device address，**不是**端口号。
   * 所以匹配必须用 busNum-devAddress，见 SharedDevice.busidCandidates()。
   *
   * 界面判断"是否已共享"只认这个结果，不靠自己记账 —— 记账一旦漏一次，
   * 开关就会显示成关闭而服务端其实还导出着，用户再点一下必然撞 busid。
   */
  /**
   * 当前包的版本串（versionName + versionCode），启动时写进日志。
   *
   * 用途只有一个：确认手机里跑的确实是最新构建。曾出现过改完代码重新打包、
   * 装上去却还是旧逻辑的情况（同 versionCode 覆盖安装被系统挡掉），
   * 光看日志无法分辨，白排查一轮。
   */
  private buildLabel(): string {
    if (this.versionText.length > 0) {
      return this.versionText;
    }
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.versionText = `v${info.versionName} (code ${info.versionCode})`;
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getBundleInfo failed: %{public}s', JSON.stringify(err));
      this.versionText = '未知版本';
    }
    return this.versionText;
  }

  private matchBusid(head: string, parts: string[]): string {
    if (head.length === 0) {
      return '';
    }
    const colon: string = `${head}:`;
    const dot: string = `${head}.`;
    for (let i = 0; i < parts.length; i++) {
      const b: string = parts[i];
      if (b === head || b.indexOf(colon) === 0 || b.indexOf(dot) === 0) {
        return b;
      }
    }
    return '';
  }

  /**
   * 服务端 busid —— 由设备身份（VID:PID[:序列号]）推导，与 native 的
   * bindDevice 用的是同一个函数，所以两边永远一致。
   *
   * 这是「同一个设备拔插后 busid 就变」的根治办法：设备地址是系统临时分配的
   * 座位号，不能当身份证用。
   */
  private stableBusidOf(d: SharedDevice): string {    try {
      const s: string = usbipNative.stableBusid(d.busNum, d.vendorId, d.productId, d.serial, d.product);
      if (s.length === 0 && !this.stableWarned) {
        this.stableWarned = true;
        this.appendLog('[绑定] 警告：native 未返回稳定 busid，回退到临时地址匹配（拔插后开关可能弹回）', LOG_WARN);
      }
      return s;
    } catch (e) {
      if (!this.stableWarned) {
        this.stableWarned = true;
        hilog.error(DOMAIN, TAG, 'stableBusid failed: %{public}s', JSON.stringify(e));
        this.appendLog(`[绑定] 警告：stableBusid 调用异常 ${JSON.stringify(e)}`, LOG_WARN);
      }
      return '';
    }
  }

  private busidOf(device: SharedDevice, bound: string): string {
    if (bound.length === 0) {
      return '';
    }
    const parts: string[] = bound.split('|');
    // 第一优先：绑定成功时 native 亲口告诉我们的 busid。
    //
    // 这是"地面真相"，不依赖任何推导/哈希。以前开关会自己弹回去，就是因为
    // 界面这边算出来的 busid 和 native 实际用的是两个值，匹配失败 → shared=false
    // → 2 秒后开关自动关掉（看起来像"点一下就退出"）。
    const cached: string = this.boundByIdentity.get(device.identity()) ?? '';
    if (cached.length > 0 && parts.indexOf(cached) >= 0) {
      return cached;
    }
    // 第二优先：按设备身份推导的稳定 busid
    const stable: string = this.stableBusidOf(device);
    if (stable.length > 0) {
      const hit: string = this.matchBusid(stable, parts);
      if (hit.length > 0) {
        return hit;
      }
    }
    // 最后才是旧的临时地址推导（兼容上一版导出的记录）
    const cands: string[] = device.busidCandidates();
    for (let c = 0; c < cands.length; c++) {
      const hit: string = this.matchBusid(cands[c], parts);
      if (hit.length > 0) {
        return hit;
      }
    }
    return '';
  }

  /** 设备已经从枚举里消失时用：只剩 name 可猜，且 name 必须是端口路径 */
  private busidByName(name: string, bound: string): string {
    if (bound.length === 0 || name.length === 0 || name.indexOf('/') >= 0) {
      return '';
    }
    return this.matchBusid(name, bound.split('|'));
  }

  private boundBusids(): string {
    try {
      return usbipNative.getBoundBusids();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'getBoundBusids failed: %{public}s', JSON.stringify(err));
      return '';
    }
  }

  /** busid 的前缀部分：`1-2:0` → `1-2`（本移植拿不到拓扑，格式恒为 总线-地址:端口） */
  private busidHead(busid: string): string {
    const c: number = busid.indexOf(':');
    return c > 0 ? busid.substring(0, c) : busid;
  }

  /**
   * 摘掉"服务端导出着、但当前根本没有对应设备"的记录。
   *
   * 这是第二阶段兜底：pruneGhosts 靠 fd 探测，能发现"设备没了但句柄还开着"；
   * 但如果某次绑定失败、或设备在两次绑定之间换过地址，服务端也可能留下一条
   * 从来没被探到的记录（比如 handler 里 native_handle 为空）。
   *
   * ── 这里踩过一个大坑，务必看清 ──
   * 老实现是拿 busid 前缀 `总线-地址` 去比当前枚举结果的 `总线-地址`。busid 改成
   * 设备身份指纹（`1-33897`）之后，这个比较永远不成立，于是**刚从服务端确认绑定
   * 成功的记录会在 2 秒后被自己摘掉**：日志里表现为
   *   [绑定] 1-2 → busid=1-33897
   *   [孤儿] 1-33897 对不上任何在线设备
   * 用户看到的就是"点一下开关就弹回去、然后连不上"。
   *
   * 正确判定：一条导出记录只要能被**任何一台在线设备**认领，就不是孤儿。
   * 认领依据依次是：native 亲口返回的 busid、按设备身份推导的稳定 busid、
   * 以及旧的临时地址候选。另外刚绑定 6 秒内的记录一律不摘（枚举抖动期）。
   *
   * @returns 是否摘掉过记录
   */
  private reapOrphans(): boolean {
    if (!this.running) {
      this.orphanRounds.clear();
      return false;
    }
    if (this.busy) {
      // 授权/连接过程中枚举会抖动，这段时间不做任何判断
      return false;
    }
    const bound: string = this.boundBusids();
    if (bound.length === 0) {
      this.orphanRounds.clear();
      return false;
    }
    if (this.devices.length === 0) {
      // 列表偶尔会整轮返回空（系统正切 USB 状态），此时不能判定"全部失效"
      return false;
    }

    // 在线设备能合法认领的所有 busid 前缀
    const alive: string[] = [];
    for (let i = 0; i < this.devices.length; i++) {
      const d: SharedDevice = this.devices[i];
      const stable: string = this.stableBusidOf(d);
      if (stable.length > 0) {
        alive.push(this.busidHead(stable));
      }
      const cached: string = this.boundByIdentity.get(d.identity()) ?? '';
      if (cached.length > 0) {
        alive.push(this.busidHead(cached));
      }
      if (stable.length === 0 && cached.length === 0) {
        // 这台设备既算不出稳定 busid、也没有绑定记录：它可能正持有一条我们
        // 认不出来的导出记录（比如上一版留下的稳定 busid）。这种情况下任何
        // "对不上" 的结论都不可信，整轮放弃判定。
        return false;
      }
      const cands: string[] = d.busidCandidates();
      for (let c = 0; c < cands.length; c++) {
        alive.push(this.busidHead(cands[c]));
      }
      if (d.busNum > 0) {
        alive.push(`${d.busNum}-${d.devAddress}`);
      }
    }

    const parts: string[] = bound.split('|');
    const nextRounds: Map<string, number> = new Map();
    const now: number = Date.now();
    let reaped: boolean = false;
    for (let i = 0; i < parts.length; i++) {
      const busid: string = parts[i];
      if (busid.length === 0) {
        continue;
      }
      if (alive.indexOf(this.busidHead(busid)) >= 0) {
        continue;
      }
      // 刚绑上的记录先放过：枚举抖动期对不上是常态
      const at: number | undefined = this.boundAt.get(busid);
      if (at !== undefined && now - at < 6000) {
        continue;
      }
      const prev: number | undefined = this.orphanRounds.get(busid);
      const rounds: number = prev === undefined ? 1 : prev + 1;
      if (rounds < 2) {
        nextRounds.set(busid, rounds);
        this.appendLog(`[孤儿] ${busid} 对不上任何在线设备（第 ${rounds}/2 轮确认）`
          + ` 在线可认领=[${alive.join(',')}]`, LOG_WARN);
        continue;
      }
      const code: number = usbipNative.notifyDeviceRemoved(busid);
      this.appendLog(`[孤儿] ${busid} 已确认失效，摘除 code=${code}`, LOG_WARN);
      this.boundAt.delete(busid);
      reaped = true;
    }
    this.orphanRounds = nextRounds;
    return reaped;
  }

  /** 打一份服务端状态快照（available / using 全列出来） */
  private logState(reason: string): void {
    let text: string = '';
    try {
      text = usbipNative.dumpState();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'dumpState failed: %{public}s', JSON.stringify(err));
      return;
    }
    if (text.length === 0) {
      return;
    }
    this.appendLog(`[快照] ${reason}`, LOG_INFO);
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      if (lines[i].length > 0) {
        this.appendLog(lines[i], LOG_INFO);
      }
    }
  }

  /** 15 秒一次的状态心跳：出问题时能看出"什么时候还是好的" */
  private heartbeatDump(): void {
    if (!this.running) {
      return;
    }
    const now: number = Date.now();
    if (now - this.lastDumpAt < 15000) {
      return;
    }
    this.lastDumpAt = now;
    this.logState('心跳');
  }

  // ---------------- 数据 ----------------

  /** 带毫秒：拔插/绑定失败往往在几百毫秒内连发，秒级时间戳分不清先后 */
  private stamp(): string {
    const d: Date = new Date();
    const hh: string = d.getHours() < 10 ? `0${d.getHours()}` : `${d.getHours()}`;
    const mm: string = d.getMinutes() < 10 ? `0${d.getMinutes()}` : `${d.getMinutes()}`;
    const ss: string = d.getSeconds() < 10 ? `0${d.getSeconds()}` : `${d.getSeconds()}`;
    const ms: number = d.getMilliseconds();
    const mss: string = ms < 100 ? (ms < 10 ? `00${ms}` : `0${ms}`) : `${ms}`;
    return `${hh}:${mm}:${ss}.${mss}`;
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
   * 复制日志到系统剪贴板。
   *
   * 只给屏幕上的 800 行还不够排查用：真正需要的是「当时的设备列表 + 服务端
   * 导出列表 + 会话状态」和日志放在一起看。所以这里先拼一段头部快照
   * （设备、busid、fd、available/using），再接原始日志。
   */
  private async copyLogs(): Promise<void> {
    // 先把缓冲一起取进来，否则最后几行（往往正是出错那几行）会漏掉
    const all: LogLine[] = this.logs.concat(this.pendingLogs);
    this.flushLogs();
    // 导出前重建一次：头部里的 shared/busid/fd 必须和服务端、service 的当前
    // 状态一致，否则日志会自相矛盾（出现过"导出列表有 1-2:0"但设备行写
    // shared=false，看日志的人会被带偏）
    this.refreshDevices();
    const now: Date = new Date();
    const lines: string[] = [];
    lines.push('===== HarmonyOS USB/IP 调试日志 =====');
    lines.push(`导出时间 ${now.getFullYear()}-${now.getMonth() + 1}-${now.getDate()} ${this.stamp()}`);
    lines.push(`包版本 ${this.buildLabel()}`);
    lines.push(`服务状态 ${this.running ? '运行中' : '已停止'} 端口=${this.portText}`
      + ` 保活=${this.keepAliveActive ? '生效' : this.keepAliveText}`);
    lines.push(`当前设备 ${this.devices.length} 台：`);
    for (let i = 0; i < this.devices.length; i++) {
      const d: SharedDevice = this.devices[i];
      lines.push(`  · ${d.label()} name=${d.name} bus=${d.busNum}-${d.devAddress}`
        + ` busid=${d.busid.length > 0 ? d.busid : '-'} fd=${d.fd}`
        + ` shared=${d.shared} sn=${d.serial.length > 0 ? d.serial : '-'}`);
    }
    const bound: string = this.boundBusids();
    lines.push(`服务端导出列表：${bound.length > 0 ? bound : '空'}`);
    try {
      const state: string = usbipNative.dumpState();
      if (state.length > 0) {
        lines.push('--- 服务端快照 ---');
        lines.push(state);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'dumpState for copy failed: %{public}s', JSON.stringify(err));
    }
    lines.push('--- 日志 ---');
    for (let i = 0; i < all.length; i++) {
      lines.push(`${all[i].time} ${all[i].text}`);
    }

    const text: string = lines.join('\n');
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      const board: pasteboard.SystemPasteboard = pasteboard.getSystemPasteboard();
      await board.setData(data);
      promptAction.showToast({ message: `已复制 ${all.length} 行日志` });
      this.appendLog(`[日志] 已复制到剪贴板（${all.length} 行，${text.length} 字）`, LOG_OK);
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'copyLogs failed: code=%{public}d msg=%{public}s', e.code, e.message);
      promptAction.showToast({ message: `复制失败 code=${e.code}` });
    }
  }

  /**
   * 刷新设备列表。
   *
   * 「是否已共享」以服务端为准（getBoundBusids），不再靠按 name 继承上一帧的
   * shared 标记：name 在拔插后会变、列表对象每帧都是新建的，任何一次继承漏掉
   * 都会让开关显示成关闭，用户再点一次就撞 busid 报错。fd 仅用于展示，继承即可。
   */
  /**
   * 清掉"设备早拔了、服务端还导着"的幽灵 busid。
   *
   * libusb 的热插拔在鸿蒙上不可用：没有 udev，且我们为了避开设备发现还开了
   * LIBUSB_OPTION_NO_DEVICE_DISCOVERY。所以服务端的拔出感知完全依赖 ArkTS
   * 上报 —— 2 秒轮询 + 两轮去抖，快速拔插必然会被吞掉一次。
   *
   * 漏掉的后果就是这次的现场：导出列表里留着 `1-2:0`，而设备已经是 `1-4:0`。
   * Windows 客户端 devlist 里两个都在，选中那个死的就回 UNBIND，弹
   * "找不到 1-2 的设备"并断开连接。
   *
   * @returns 是否真的清理过（调用方据此决定要不要重建列表状态）
   */
  private pruneGhosts(): boolean {
    if (!this.running) {
      return false;
    }
    const now: number = Date.now();
    // 3 秒太密：探测会在 native 侧持全局锁做控制传输（每个设备最多 100ms），
    // 每 3 秒来一次会和界面的状态查询抢锁，长时间运行后表现为卡顿。而且
    // available 设备的 fd 失效并不紧急——没人用它。10 秒足够。
    if (now - this.lastPruneAt < 10000) {
      return false;
    }
    this.lastPruneAt = now;
    let dead: string = '';
    try {
      dead = usbipNative.pruneDeadDevices();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'pruneDeadDevices failed: %{public}s', JSON.stringify(err));
      return false;
    }
    if (dead.length === 0) {
      return false;
    }
    this.appendLog(`[清理] 已移除失效的导出记录 ${dead}`, LOG_WARN);
    return true;
  }

  private refreshDevices(): void {
    const list: SharedDevice[] = this.service.list();
    const bound: string = this.boundBusids();
    // 清掉已经不在导出列表里的缓存项（拔插、清理幽灵记录之后）
    this.boundByIdentity.forEach((v: string, k: string) => {
      if (bound.indexOf(v) < 0) {
        this.boundByIdentity.delete(k);
      }
    });
    for (let i = 0; i < list.length; i++) {
      const busid: string = this.busidOf(list[i], bound);
      list[i].busid = busid;
      list[i].shared = busid.length > 0;
      // fd 只从 service 取，不再从上一帧的列表对象继承：
      // 同一端口拔插后 name 不变，继承过来的 fd 早已失效，却会被当成"活的"
      // 用在幂等判断里，结果就是服务端拿着死 fd 继续导出一个幽灵设备。
      list[i].fd = this.service.fdOf(list[i].name);
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
      this.logState('服务启动');
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
    this.lastDumpAt = 0;
    this.orphanRounds.clear();
    this.appendLog('[服务] 已停止，所有导出记录随服务端一起销毁', LOG_WARN);
    await keepAlive.stop();
    this.busy = false;
  }

  /** 开关入口：按目标状态分发 */
  private async setShared(device: SharedDevice, wantOn: boolean): Promise<void> {
    if (!this.running) {
      promptAction.showToast({ message: '请先启动服务' });
      this.refreshDevices();
      return;
    }
    if (wantOn === device.shared) {
      return;
    }
    // 同一台设备的操作做个 600ms 冷却：连点、以及"点了之后列表刚好刷新"
    // 这类时序问题都会产生第二次反向操作，而每次解绑都会 close 掉 fd，
    // 客户端正在用的话直接就断了。
    const now: number = Date.now();
    const last: number = this.lastActionAt.get(device.name) ?? 0;
    if (now - last < 600) {
      this.appendLog(`[开关] ${device.name} 操作过于频繁（${now - last}ms），忽略`, LOG_WARN);
      return;
    }
    this.lastActionAt.set(device.name, now);
    if (wantOn) {
      await this.shareDevice(device);
    } else {
      await this.unshareDevice(device);
    }
  }

  /**
   * 打开并绑定一台设备（幂等，可重复点）。
   *
   * fd 复用很关键：以前每次绑定都 closeDevice + openDevice，等于让内核重新
   * 走一遍 usbfs 打开流程（释放已 claim 的接口、设备复位）。设备被复位时
   * 客户端的 URB 全部作废，表现就是"刚连上就掉、反复重连"。现在只要管道还
   * 在就直接沿用，只有真的没有 fd（或它已经失效）才重新打开。
   */
  private async shareDevice(device: SharedDevice): Promise<boolean> {
    this.busy = true;
    try {
      const bound: string = this.busidOf(device, this.boundBusids());
      const alive: number = this.service.fdOf(device.name);

      // ---- 幂等第一层：服务端已经导出着，且我们手上还有个活着的 fd ----
      // 此时不能再 closeDevice + openDevice：换来的新 fd 和 busid 会和旧记录
      // 撞（服务端按 busid 查重直接拒绝），而旧记录里的 fd 已经被我们关掉，
      // 客户端一连就断。最优做法是什么都不做。
      if (bound.length > 0 && alive >= 0) {
        device.shared = true;
        device.busid = bound;
        device.fd = alive;
        this.appendLog(`[绑定] ${device.name} 已在共享中（busid=${bound}），跳过`, LOG_INFO);
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

      let fd: number = alive;
      if (fd < 0) {
        fd = await this.service.openDevice(device.name);
      } else {
        this.appendLog(`[打开] ${device.name} 复用已有 fd=${fd}`, LOG_INFO);
      }
      if (fd < 0) {
        this.appendLog(`[打开] ${device.name} 失败（授权被拒或系统占用）`, LOG_ERROR);
        promptAction.showToast({ message: '打开设备失败' });
        this.refreshDevices();
        return false;
      }
      const want: string = this.stableBusidOf(device);
      this.appendLog(`[打开] ${device.name} fd=${fd} 稳定 busid=${want}（临时地址 ${device.busNum}-${device.devAddress}）`, LOG_INFO);
      let code: number = usbipNative.bindDevice(fd, want);

      // [稳定性] fd 失效后的自愈重试。
      //
      // 设备长时间插着不动的时候，USB 栈可能被系统重置（省电策略、USB 服务
      // 重启、供电波动），此时旧的 usbfs fd 已经失效，而 usbManager 给出的
      // name 不会变 —— openDevice() 命中缓存直接把死 fd 交回来，绑定必然失败。
      // 以前这里直接放弃，用户只能拔插一次才能恢复，表现就是"断了一次之后
      // 怎么连都连不上"。这类错误码全都是"句柄不可用"，重开一次就能好。
      if (code !== 0 && this.shouldReopenFd(code)) {
        this.appendLog(`[绑定] ${device.name} 失败 code=${code}${this.explainBindCode(code)}，重建句柄后重试`, LOG_WARN);
        this.service.closeDevice(device.name);
        const again: number = await this.service.openDevice(device.name);
        if (again >= 0) {
          fd = again;
          code = usbipNative.bindDevice(again, want);
          this.appendLog(`[绑定] ${device.name} 重试${code === 0 ? '成功' : `仍失败 code=${code}`} fd=${again}`,
            code === 0 ? LOG_OK : LOG_ERROR);
        }
      }

      if (code !== 0) {
        this.service.closeDevice(device.name);
        this.appendLog(`[绑定] ${device.name} 失败 code=${code}${this.explainBindCode(code)}`, LOG_ERROR);
        promptAction.showToast({ message: `绑定失败 code=${code}` });
        this.refreshDevices();
        this.logState('绑定失败后');
        return false;
      }
      device.shared = true;
      device.fd = fd;
      device.busid = usbipNative.getLastBusid();
      // 记下地面真相：开关状态以后就按它来匹配，不再依赖任何推导
      this.boundByIdentity.set(device.identity(), device.busid);
      // 记下绑定时刻：刚绑上的 6 秒内不参与孤儿判定（枚举会短暂缺项）
      this.boundAt.set(device.busid, Date.now());
      this.appendLog(`[绑定] ${device.name} → busid=${device.busid}`, LOG_OK);
      // 自检：刚绑上就查一遍服务端导出列表，对不上说明界面和 native 的
      // busid 口径已经分叉了 —— 这种问题不报出来，表现就是"开关自己弹回去"
      const nowBound: string[] = this.boundBusids().split('|');
      if (nowBound.indexOf(device.busid) < 0) {
        this.appendLog(`[绑定] 自检失败：服务端导出列表里没有 ${device.busid}（现有 ${this.boundBusids()}）`, LOG_ERROR);
      }
      this.devices = this.devices.slice();
      this.logState('绑定后');
      return true;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'shareDevice failed: %{public}s', JSON.stringify(err));
      return false;
    } finally {
      this.busy = false;
    }
  }

  /**
   * 这些错误码的共同点：**手上的 fd 已经不可用了**，而不是"服务端不让绑"。
   * 重建一次句柄有实质意义；其余（已导出、设备忙）重试只会白撞。
   */
  private shouldReopenFd(code: number): boolean {
    return code === 1 || code === 3 || code === 4 || code === 5 || code === 6;
  }

  /** 绑定错误码的人话解释，省得每次还要翻源码 */
  private explainBindCode(code: number): string {    switch (code) {
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
   * 解绑并关闭一台设备。
   *
   * 必须按 busid 走「设备移除」通道，不能用 unbindDevice(fd)：
   * 设备正被客户端使用时，unbind_host_device_by_fd 会返回 DeviceInUse 且
   * 什么都不做 —— 界面关了、服务端还导着，这就是下次打不开的直接原因。
   */
  private async unshareDevice(device: SharedDevice): Promise<void> {
    let busid: string = device.busid;
    if (busid.length === 0) {
      busid = this.busidOf(device, this.boundBusids());
    }

    let code: number = -1;
    if (busid.length > 0) {
      code = usbipNative.notifyDeviceRemoved(busid);
    } else if (device.fd >= 0) {
      code = usbipNative.unbindDevice(device.fd);
    }

    this.appendLog(code === 0 ? `[解绑] ${device.name} busid=${busid} 已提交`
      : `[解绑] ${device.name} 失败 code=${code}`, code === 0 ? LOG_OK : LOG_ERROR);
    if (code === 0) {
      this.boundByIdentity.delete(device.identity());
      this.boundAt.delete(busid);
    }
    this.service.closeDevice(device.name);
    device.shared = false;
    device.fd = -1;
    device.busid = '';
    this.devices = this.devices.slice();

    if (code === 0 && busid.length > 0) {
      // using 状态下踢会话是异步的，等它真的从导出列表消失再收敛 UI，
      // 否则下一轮 refresh 会把开关又弹回"开"
      this.settleUnbind(device, busid, 0);
    }
  }

  /** 解绑后的收敛：每 50ms 查一次服务端，最多 600ms，不阻塞 UI */
  private settleUnbind(device: SharedDevice, busid: string, round: number): void {
    const still: boolean = this.busidOf(device, this.boundBusids()).length > 0;
    if (!still) {
      if (round > 0) {
        this.appendLog(`[解绑] ${device.name} 已从导出列表移除`, LOG_OK);
      }
      this.refreshDevices();
      this.logState('解绑后');
      return;
    }
    if (round >= 12) {
      this.appendLog(`[解绑] ${device.name} 仍在导出列表（客户端可能还连着）`, LOG_WARN);
      this.refreshDevices();
      this.logState('解绑未收敛');
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
        // 版本水印：排查时第一眼看这里，就能确认跑的是不是最新构建
        Text(this.buildLabel())
          .fontSize(11)
          .fontColor(C_LABEL3)
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
            // ForEach 按 name 复用组件，捕获的 device 可能已经被 refreshDevices
            // 换成了旧对象；按 name 取当前对象，避免把状态改在一份孤儿数据上
            this.probe(this.liveOf(device));
          })

        // 自己画的开关，不用 Toggle。
        //
        // Toggle 的 isOn 是单向入参：程序里把 shared 改成 true 后，ArkUI 会在
        // 下一帧用新的 isOn 重建开关，并把这次"程序改动"当成一次用户操作回推
        // 一次 onChange。debug 日志里 `[绑定] 1-4 → busid=1-4:0` 和
        // `[解绑] 1-4 busid=1-4:0 已提交` 相隔 1 毫秒，就是这么来的 ——
        // 刚绑上就被自己解绑，fd 反复 close/reopen，设备被反复复位，客户端
        // 那边自然"看起来连上了却什么都没发生"。
        //
        // 这个开关只有 onClick 一个入口，状态永远只由服务端导出列表决定，
        // 不存在框架反向回推的可能。
        Stack() {
          Circle()
            .width(25)
            .height(25)
            .fill(Color.White)
            .shadow({ radius: 2, color: '#26000000', offsetY: 1 })
            .position({ x: device.shared ? 23 : 3, y: 3 })
            .animation({ duration: 160, curve: Curve.EaseOut })
        }
        .width(51)
        .height(31)
        .borderRadius(15.5)
        .backgroundColor(device.shared ? C_GREEN : '#E9E9EB')
        .animation({ duration: 160, curve: Curve.EaseOut })
        .enabled(!this.busy)
        .opacity(this.busy ? 0.5 : 1)
        .onClick(() => {
          const live: SharedDevice = this.liveOf(device);
          this.setShared(live, !live.shared);
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
          }, (device: SharedDevice) => `${device.name}|${device.shared}|${device.fd}|${device.busid}`)
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
      Row({ space: 16 }) {
        this.caption('运行日志')
        Blank()
        Text('复制')
          .fontSize(15)
          .fontColor(C_BLUE)
          .onClick(() => {
            this.copyLogs();
          })
        Text('清空')
          .fontSize(15)
          .fontColor(C_BLUE)
          .onClick(() => {
            this.logs = [];
            this.pendingLogs = [];
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
