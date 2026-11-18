import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SharedDevice, hex4 } from './UsbDeviceService';

const DOMAIN = 0x3200;
const TAG = 'UsbIpMem';

const STORE_NAME = 'usbip_prefs';
const KEY_REMEMBERED = 'remembered_devices';

/**
 * 「记得这台设备」的名册。
 *
 * 以 SharedDevice.identity()（vid:pid:serial）作为键落盘，因此换设备地址、
 * 拔插、甚至换 USB 口都还能认出来。用户把某台设备的共享开关打开时就记住它，
 * 下次插上自动重新共享，不必再进 App 点一次。
 */
export class DeviceMemory {
  private keys: string[] = [];
  private store: preferences.Preferences | null = null;
  private ready: boolean = false;

  async init(ctx: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(ctx, STORE_NAME);
      const raw: string = await this.store.get(KEY_REMEMBERED, '') as string;
      if (raw.length > 0) {
        const parsed: string[] = JSON.parse(raw) as string[];
        this.keys = parsed;
      }
      this.ready = true;
      hilog.info(DOMAIN, TAG, '已加载 %{public}d 台记住的设备', this.keys.length);
    } catch (err) {
      // 读盘失败不该拦住主流程，降级为「本次运行内有效」
      hilog.error(DOMAIN, TAG, 'preferences 初始化失败: %{public}s', JSON.stringify(err));
      this.ready = false;
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  /**
   * 是否在名册里。
   *
   * 先按完整身份（vid:pid:serial）精确匹配；不命中再退一步只比 vid:pid。
   * 退这一步是必要的：部分设备的序列号并非每次都能读到（第一次读到、
   * 之后为空），严格匹配会直接失配，用户看到的就是「记住过却不自动打开」。
   */
  has(device: SharedDevice): boolean {
    if (this.keys.indexOf(device.identity()) >= 0) {
      return true;
    }
    return this.hasPrefix(`${hex4(device.vendorId)}:${hex4(device.productId)}`);
  }

  private hasPrefix(prefix: string): boolean {
    for (let i = 0; i < this.keys.length; i++) {
      if (this.keys[i].indexOf(prefix) === 0) {
        return true;
      }
    }
    return false;
  }

  hasKey(key: string): boolean {
    return this.keys.indexOf(key) >= 0;
  }

  /** 记住一台设备（用户手动打开共享时调用） */
  async remember(device: SharedDevice): Promise<void> {
    const key: string = device.identity();
    if (this.keys.indexOf(key) >= 0) {
      return;
    }
    this.keys.push(key);
    await this.persist();
    hilog.info(DOMAIN, TAG, '已记住设备 %{public}s', key);
  }

  /** 忘掉一台设备（用户手动关闭共享时调用） */
  async forget(device: SharedDevice): Promise<void> {
    const key: string = device.identity();
    const idx: number = this.keys.indexOf(key);
    if (idx < 0) {
      return;
    }
    this.keys.splice(idx, 1);
    await this.persist();
    hilog.info(DOMAIN, TAG, '已忘记设备 %{public}s', key);
  }

  count(): number {
    return this.keys.length;
  }

  private async persist(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.put(KEY_REMEMBERED, JSON.stringify(this.keys));
      await this.store.flush();
    } catch (err) {
      hilog.error(DOMAIN, TAG, '写入失败: %{public}s', JSON.stringify(err));
    }
  }
}
