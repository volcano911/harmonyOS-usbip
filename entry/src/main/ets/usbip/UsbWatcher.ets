import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SharedDevice } from './UsbDeviceService';

const DOMAIN = 0x3200;
const TAG = 'UsbIpWatch';

/** 系统广播的 USB 插拔公共事件（由系统发布，应用侧只订阅） */
const EVENT_ATTACHED = 'usual.event.hardware.usb.action.USB_DEVICE_ATTACHED';
const EVENT_DETACHED = 'usual.event.hardware.usb.action.USB_DEVICE_DETACHED';

/**
 * USB 插拔监听。
 *
 * 鸿蒙的 @ohos.usbManager 没有 on('attach'/'detach')，只能靠系统公共事件。
 * 但公共事件是否放行给三方应用没有保证，所以这里做两层：
 *   1. 订阅 USB_DEVICE_ATTACHED / DETACHED，能收到就是毫秒级响应；
 *   2. 同时每 2 秒轮询一次 usbManager.getDevices() 兜底。
 * 两者都走同一个 diff，重复触发不会重复上报。
 */
export class UsbWatcher {
  /**
   * name → 上一轮看到的设备快照。
   *
   * 必须存整个 SharedDevice，不能只存 identity：设备拔出时它已经从
   * getDevices() 里消失，界面层再也拿不到它的 busNum/devAddress，
   * 也就没法反推出它在服务端对应的 busid（`1-2:0`）。只剩 name 的话，
   * 拔出通知必然发不出去，服务端就永远留着那条导出记录 —— 客户端下次
   * attach 它就会得到「找不到busid为X的设备」。
   */
  private known: Map<string, SharedDevice> = new Map();
  /** name → 连续几轮没枚举到（拔出去抖） */
  private missRounds: Map<string, number> = new Map();
  private timer: number = -1;
  private subscriber: commonEventManager.CommonEventSubscriber | null = null;
  private provider: () => SharedDevice[];
  private eventsOk: boolean = false;

  /**
   * 连续多少轮看不到才算拔掉。
   *
   * getDevices() 会抖动：requestRight / connectDevice 正在切设备状态的那几秒，
   * 枚举结果可能缺项。一轮就上报 detach 会引发连锁反应 —— 清掉自动绑定记录、
   * 关掉正在用的 fd，紧接着下一轮又当成"新插入"重新绑定，服务端于是报
   * busid 已存在。2s × 2 足以跨过抖动。
   */
  private static readonly GONE_ROUNDS: number = 2;

  onAttached: (device: SharedDevice) => void = () => {
  };
  /** 带整份快照：拔出后只有它还记得这台设备的 busNum/devAddress */
  onDetached: (device: SharedDevice) => void = () => {
  };
  onListChanged: () => void = () => {
  };
  /**
   * 每轮都会调，不管列表有没有变化。
   *
   * 给"不依赖设备列表的健康检查"用：拔线漏报时服务端会残留一个已经不存在的
   * busid，而 usbManager 的枚举结果看起来完全正常，onListChanged 永远不会
   * 触发。这类检查必须自己有时间基准。
   */
  onTick: () => void = () => {
  };

  constructor(provider: () => SharedDevice[]) {
    this.provider = provider;
  }

  isEventDriven(): boolean {
    return this.eventsOk;
  }

  async start(intervalMs: number = 2000): Promise<void> {
    if (this.timer !== -1) {
      return;
    }
    await this.subscribeEvents();
    this.tick(); // 启动时先扫一次，已在插着的设备也能被认出来
    this.timer = setInterval(() => {
      this.tick();
    }, intervalMs);
    hilog.info(DOMAIN, TAG, '监听已启动，事件订阅=%{public}s', this.eventsOk ? '可用' : '不可用，走轮询');
  }

  stop(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.unsubscribeEvents();
  }

  /** 手动强制重扫（下拉/点刷新时用） */
  rescan(): void {
    this.tick();
  }

  private async subscribeEvents(): Promise<void> {
    try {
      const info: commonEventManager.CommonEventSubscribeInfo = {
        events: [EVENT_ATTACHED, EVENT_DETACHED]
      };
      const subscriber: commonEventManager.CommonEventSubscriber =
        await commonEventManager.createSubscriber(info);
      await commonEventManager.subscribe(subscriber, (err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, '事件回调报错: %{public}s', JSON.stringify(err));
          return;
        }
        // 事件体里不带设备对象，统一重扫一次即可
        this.tick();
      });
      this.subscriber = subscriber;
      this.eventsOk = true;
    } catch (err) {
      // 三方应用无权订阅时（201/801）会到这里，退化成纯轮询
      this.eventsOk = false;
      hilog.warn(DOMAIN, TAG, '公共事件订阅不可用，改用轮询: %{public}s', JSON.stringify(err));
    }
  }

  private unsubscribeEvents(): void {
    const subscriber: commonEventManager.CommonEventSubscriber | null = this.subscriber;
    this.subscriber = null;
    this.eventsOk = false;
    if (subscriber === null) {
      return;
    }
    try {
      commonEventManager.unsubscribe(subscriber, (err: BusinessError) => {
        if (err) {
          hilog.warn(DOMAIN, TAG, '退订失败: %{public}s', JSON.stringify(err));
        }
      });
    } catch (err) {
      hilog.warn(DOMAIN, TAG, '退订异常: %{public}s', JSON.stringify(err));
    }
  }

  private tick(): void {
    // 先跑与列表无关的检查（服务端幽灵设备），再算差集
    this.onTick();
    const list: SharedDevice[] = this.provider();
    const next: Map<string, SharedDevice> = new Map();
    const attached: SharedDevice[] = [];

    for (let i = 0; i < list.length; i++) {
      const d: SharedDevice = list[i];
      next.set(d.name, d);
      if (!this.known.has(d.name)) {
        attached.push(d);
      }
      this.missRounds.delete(d.name);
    }

    const gone: SharedDevice[] = [];
    this.known.forEach((device: SharedDevice, name: string) => {
      if (next.has(name)) {
        return;
      }
      const prev: number | undefined = this.missRounds.get(name);
      const rounds: number = prev === undefined ? 1 : prev + 1;
      if (rounds >= UsbWatcher.GONE_ROUNDS) {
        gone.push(device);
        this.missRounds.delete(name);
      } else {
        // 还没确认拔出：保留在 known 里，否则下一轮会被误判成"新插入"
        this.missRounds.set(name, rounds);
        next.set(name, device);
      }
    });

    // 先处理移除再处理新增：设备换口重插时地址会变，先清掉旧记录更稳妥
    for (let i = 0; i < gone.length; i++) {
      this.onDetached(gone[i]);
    }
    for (let i = 0; i < attached.length; i++) {
      this.onAttached(attached[i]);
    }

    const changed: boolean = gone.length > 0 || attached.length > 0;
    this.known = next;
    if (changed) {
      this.onListChanged();
    }
  }
}
