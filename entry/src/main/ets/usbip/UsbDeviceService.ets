import { usbManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x3200;
const TAG = 'UsbIpSvc';

/** 4 位十六进制（本 SDK 的 ArkTS 上 String.padStart 不可靠，手写） */
export function hex4(value: number): string {
  let s: string = value.toString(16);
  while (s.length < 4) {
    s = `0${s}`;
  }
  return s;
}

/**
 * 一台可被共享的 USB 设备。
 *
 * fd 的来源是本文件 openDevice() 里的 usbManager.getFileDescriptor(pipe)。
 * 关键纪律（华为官方 FAQ 明确）：用 libusb 时**不要**调用 claimInterface /
 * setConfiguration / setInterface —— USB 服务进程会独占接口，之后 libusb 的
 * USBDEVFS_SUBMITURB ioctl 会返回 EBUSY(errno=16)。接口由 libusb 自己 claim。
 */
export class SharedDevice {
  name: string = '';
  vendorId: number = 0;
  productId: number = 0;
  manufacturer: string = '';
  product: string = '';
  clazz: number = 0;
  /** 设备序列号；部分设备不提供，此时为空串 */
  serial: string = '';
  /** USB 总线号。与 devAddress 一起构成 busid 的前缀，见 busidCandidates() */
  busNum: number = 0;
  /** 设备地址（usbfs 上叫 devnum），每次插拔由系统重新分配 */
  devAddress: number = 0;
  fd: number = -1;
  /** 绑定成功后的 busid，解绑/掉线通知用 */
  busid: string = '';
  shared: boolean = false;

  constructor(d: Readonly<usbManager.USBDevice>) {
    this.name = d.name;
    this.vendorId = d.vendorId;
    this.productId = d.productId;
    this.manufacturer = d.manufacturerName ?? '';
    this.product = d.productName ?? '';
    this.clazz = d.clazz;
    this.serial = d.serial ?? '';
    this.busNum = d.busNum;
    this.devAddress = d.devAddress;
  }

  /**
   * 跨越插拔的稳定身份。
   *
   * devAddress（也就是 busid 里 `1-2` 的那个 2）每次插拔都会变，不能当身份。
   * 有序列号时 vid:pid:serial 唯一；没有序列号只能退到 vid:pid:产品名，
   * 此时两个同型号设备会被认成同一台（可接受，日志里会写明）。
   */
  identity(): string {
    const vid: string = hex4(this.vendorId);
    const pid: string = hex4(this.productId);
    if (this.serial.length > 0) {
      return `${vid}:${pid}:${this.serial}`;
    }
    return `${vid}:${pid}:${this.product}`;
  }

  /** 是否具备可靠身份（有序列号） */
  hasStableIdentity(): boolean {
    return this.serial.length > 0;
  }

  /**
   * 服务端 busid 的所有可能前缀，按可信度排序。
   *
   * busid 由 libusb 的 get_device_busid() 生成，两条分支：
   *   1) 能读到拓扑端口时 → `总线-端口[.端口]`，例如 `1-4`
   *   2) 读不到时（本移植走的就是这条，鸿蒙没有 sysfs 拓扑）→
   *      `总线-设备地址:端口`，例如 `1-2:0`
   *
   * 所以第 2 种必须用 busNum-devAddress 来对，而**不能**用 name —— name 是
   * USB 服务给的名字，与 libusb 的地址无关。之前拿 name 当后缀前缀匹配，
   * 匹配不上就会把"已共享"误判成"未共享"，然后重复绑定撞 AlreadyBound。
   */
  busidCandidates(): string[] {
    const out: string[] = [];
    if (this.busNum > 0) {
      out.push(`${this.busNum}-${this.devAddress}`);
    }
    if (this.name.length > 0 && this.name.indexOf('/') < 0) {
      // 兼容拓扑可用的机器：此时 busid 就是端口路径，name 恰好也长这样
      out.push(this.name);
    }
    return out;
  }

  label(): string {
    const name: string = this.product.length > 0 ? this.product : '未知设备';
    return `${name} (${this.vendorId.toString(16)}:${this.productId.toString(16)})`;
  }
}

export class UsbDeviceService {
  /** 保活持有的 pipe：fd 的有效性依附于 pipe，解绑前不能关 */
  private pipes: Map<string, usbManager.USBDevicePipe> = new Map();
  private fds: Map<string, number> = new Map();
  /** name → 连续几轮 getDevices() 没看到它（用于拔插去抖） */
  private missingRounds: Map<string, number> = new Map();

  /**
   * 连续多少轮看不到才算真拔掉。
   *
   * 为什么不能"一轮看不到就回收"：connectDevice / requestRight 期间
   * usbManager 的枚举结果会短暂缺项（系统内部正在切设备状态），一轮就回收
   * 会把刚拿到、正在用的 fd 关掉 —— 这正是"绑定成功后立刻又绑不上、或者
   * 客户端连上就断"的根源。2s 一轮 × 3 = 6s，足够跨过任何抖动。
   */
  private static readonly PRUNE_ROUNDS: number = 3;

  /** 枚举当前接入的设备（Host 模式） */
  list(): SharedDevice[] {
    const out: SharedDevice[] = [];
    try {
      const devices: Array<Readonly<usbManager.USBDevice>> = usbManager.getDevices();
      const present: string[] = [];
      for (let i = 0; i < devices.length; i++) {
        const d: Readonly<usbManager.USBDevice> = devices[i];
        present.push(d.name);
        out.push(new SharedDevice(d));
      }
      // 拿到完整列表后再回收，避免 getDevices 抛异常时把缓存全清空
      this.prune(present);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'getDevices failed: %{public}s', JSON.stringify(err));
    }
    return out;
  }

  /**
   * 回收已经不在列表里的设备句柄（带去抖）。
   *
   * 必须做：usbfs 的设备地址会被复用，拔掉再插上很可能又是同一个 name。
   * 如果不清缓存，openDevice() 会命中一条早已失效的旧 fd，绑定必然失败。
   * 但又不能清太急 —— 见 PRUNE_ROUNDS 的说明。
   */
  private prune(present: string[]): void {
    const stale: string[] = [];
    this.fds.forEach((_fd: number, name: string) => {
      if (present.indexOf(name) >= 0) {
        this.missingRounds.delete(name);
        return;
      }
      const prev: number | undefined = this.missingRounds.get(name);
      const rounds: number = prev === undefined ? 1 : prev + 1;
      if (rounds >= UsbDeviceService.PRUNE_ROUNDS) {
        stale.push(name);
      } else {
        this.missingRounds.set(name, rounds);
      }
    });
    for (let i = 0; i < stale.length; i++) {
      hilog.info(DOMAIN, TAG, '设备已移除，回收句柄: %{public}s', stale[i]);
      this.closeDevice(stale[i]);
    }
  }

  /**
   * 打开设备并拿到 fd。
   *
   * 顺序照搬华为官方 libusb 示例：requestRight → connectDevice → getFileDescriptor，
   * 中间不碰 claimInterface。
   */
  async openDevice(name: string): Promise<number> {
    const cached: number | undefined = this.fds.get(name);
    if (cached !== undefined && cached >= 0) {
      return cached;
    }
    const devices: Array<Readonly<usbManager.USBDevice>> = usbManager.getDevices();
    let target: Readonly<usbManager.USBDevice> | undefined = undefined;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].name === name) {
        target = devices[i];
        break;
      }
    }
    if (target === undefined) {
      hilog.error(DOMAIN, TAG, '设备不存在: %{public}s', name);
      return -1;
    }

    const granted: boolean = await usbManager.requestRight(target.name);
    if (!granted) {
      hilog.error(DOMAIN, TAG, '用户拒绝授权: %{public}s', name);
      return -1;
    }

    const pipe: usbManager.USBDevicePipe = usbManager.connectDevice(target);
    const fd: number = usbManager.getFileDescriptor(pipe);
    if (fd < 0) {
      usbManager.closePipe(pipe);
      hilog.error(DOMAIN, TAG, 'getFileDescriptor 返回 %{public}d', fd);
      return -1;
    }
    this.pipes.set(name, pipe);
    this.fds.set(name, fd);
    hilog.info(DOMAIN, TAG, '已打开 %{public}s, fd=%{public}d', name, fd);
    return fd;
  }

  /** 关闭设备，释放 fd（必须先让 native 侧解绑） */
  closeDevice(name: string): void {
    const pipe: usbManager.USBDevicePipe | undefined = this.pipes.get(name);
    if (pipe !== undefined) {
      try {
        usbManager.closePipe(pipe);
      } catch (err) {
        hilog.warn(DOMAIN, TAG, 'closePipe failed: %{public}s', JSON.stringify(err));
      }
    }
    this.pipes.delete(name);
    this.fds.delete(name);
    this.missingRounds.delete(name);
  }

  fdOf(name: string): number {
    const fd: number | undefined = this.fds.get(name);
    return fd === undefined ? -1 : fd;
  }

  /** 是否有打开的句柄（不保证 fd 对应设备还插着） */
  isOpen(name: string): boolean {
    const fd: number | undefined = this.fds.get(name);
    return fd !== undefined && fd >= 0;
  }

  closeAll(): void {
    const names: string[] = [];
    this.pipes.forEach((_pipe: usbManager.USBDevicePipe, key: string) => {
      names.push(key);
    });
    for (let i = 0; i < names.length; i++) {
      this.closeDevice(names[i]);
    }
  }
}
