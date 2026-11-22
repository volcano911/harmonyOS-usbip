/**
 * 长时任务保活。
 *
 * 为什么必须有它：鸿蒙对三方应用进入后台后的处理是「先降频、再冻结、
 * 约 10 分钟后挂起进程」。进程一挂起，native 侧 usbipdcpp 的事件循环不再
 * 跑，libusb 的 USBDEVFS_SUBMITURB 也不再提交，客户端那边看到的就是
 * 「连接莫名其妙断了」——这正是阿西西那版 10 来分钟断开的成因。
 *
 * 解法是申请 ContinuousTask（长时任务），类型选 dataTransfer：
 *   - 系统会为该任务挂一条不可划掉的常驻通知；
 *   - 任务有效期内进程不被冻结，CPU 也不被降档；
 *   - 代价是「必须真在传数据」，系统会校验，所以不能拿它当万能免死金牌。
 *
 * 注意 TASK_KEEPING（任务保持）类型虽然语义最贴合，但它要求系统应用
 * （startBackgroundRunning 会抛 202 Not System App），三方应用走不通，
 * 所以这里只能用 dataTransfer。
 */

import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0x3200;
const TAG = 'UsbIpKeepAlive';

/**
 * 被系统取消后自动重启的最大次数。
 *
 * 原来是 3。但"用久了十几二十分钟突然连不上"最典型的成因就是长时任务被系统
 * 取消（内存管控、判定没有真实数据传输），进程随后被冻结，native 的 socket
 * 与 USB 事件循环一起停摆 —— 客户端看到的就是连接毫无征兆地断掉。3 次在
 * 一次稍微长的调试会话里根本不够用（用户往往几小时不碰前台），提到 8 次，
 * 配合退避大约能覆盖十分钟以上的反复取消。
 */
const MAX_AUTO_RESTART: number = 8;
/** 首次重启等待；之后按次数退避，见 tryAutoRestart */
const RESTART_DELAY_MS: number = 3000;
/** 退避上限：再慢就不如直接提示用户回前台了 */
const RESTART_DELAY_MAX_MS: number = 30000;

export interface KeepAliveState {
  active: boolean;
  /** 可直接展示给用户的原因描述 */
  detail: string;
}

export type KeepAliveListener = (state: KeepAliveState) => void;

export class KeepAlive {
  private taskId: number = -1;
  private active: boolean = false;
  private listener: KeepAliveListener | undefined = undefined;
  private ctx: common.UIAbilityContext | undefined = undefined;
  private callbacksBound: boolean = false;
  private restartCount: number = 0;
  /** start() 进行中的标记，防止并发重复申请 */
  private starting: boolean = false;

  onStateChange(cb: KeepAliveListener): void {
    this.listener = cb;
  }

  isActive(): boolean {
    return this.active;
  }

  taskIdOf(): number {
    return this.taskId;
  }

  private emit(active: boolean, detail: string): void {
    this.active = active;
    if (this.listener !== undefined) {
      this.listener({ active: active, detail: detail });
    }
  }

  /**
   * 申请长时任务。
   *
   * 传 string[] 的重载（API 12+）才会返回 taskId，用于后续单任务停止；
   * 老的单枚举重载拿不到 id，出问题不好收尾。
   */
  async start(ctx: common.UIAbilityContext): Promise<boolean> {
    if (this.active) {
      return true;
    }
    if (this.starting) {
      return false;
    }
    this.starting = true;
    this.ctx = ctx;

    try {
      const want: WantAgent = await this.buildWantAgent(ctx);
      const notification: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(ctx, ['dataTransfer'], want);
      const id: number | undefined = notification.continuousTaskId;
      this.taskId = id === undefined ? -1 : id;
      this.bindSuspendEvents();
      this.restartCount = 0;
      this.starting = false;
      this.emit(true, `长时任务已生效 (id=${this.taskId})，后台不再被冻结`);
      hilog.info(DOMAIN, TAG, 'continuous task started, id=%{public}d', this.taskId);
      return true;
    } catch (e) {
      const err = e as BusinessError;
      this.starting = false;
      const reason: string = this.explain(err.code);
      this.emit(false, reason);
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning failed: %{public}d %{public}s', err.code, err.message);
      return false;
    }
  }

  /** 主动停止（用户点「停止服务」时调用） */
  async stop(): Promise<void> {
    this.restartCount = MAX_AUTO_RESTART; // 主动停止后不要再自动拉起
    this.unbindSuspendEvents();
    if (!this.active && this.taskId < 0) {
      return;
    }
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined) {
      this.emit(false, '长时任务已释放');
      this.taskId = -1;
      return;
    }
    try {
      if (this.taskId >= 0) {
        await backgroundTaskManager.stopBackgroundRunning(ctx, this.taskId);
      } else {
        await backgroundTaskManager.stopBackgroundRunning(ctx);
      }
      hilog.info(DOMAIN, TAG, 'continuous task stopped');
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stopBackgroundRunning failed: %{public}d %{public}s', err.code, err.message);
    }
    this.taskId = -1;
    this.emit(false, '长时任务已释放');
  }

  /** 构造点击通知回到本应用的 WantAgent */
  private async buildWantAgent(ctx: common.UIAbilityContext): Promise<WantAgent> {
    const info: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };
    return await wantAgent.getWantAgent(info);
  }

  /** 监听被系统取消/挂起，用于给 UI 一个真实原因，并在可恢复时自动重来 */
  private bindSuspendEvents(): void {
    if (this.callbacksBound) {
      return;
    }
    this.callbacksBound = true;

    backgroundTaskManager.on('continuousTaskCancel',
      (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        const why: string = this.explainCancel(info.reason);
        hilog.warn(DOMAIN, TAG, 'continuous task canceled, reason=%{public}d', info.reason);
        this.taskId = -1;
        this.emit(false, why);
        this.tryAutoRestart(why);
      });

    // @since 20：系统主动暂停（还没取消），可恢复
    backgroundTaskManager.on('continuousTaskSuspend',
      (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
        hilog.warn(DOMAIN, TAG, 'continuous task suspended');
        this.emit(false, '长时任务被系统暂停，正在恢复');
        this.tryAutoRestart('被系统暂停');
      });
  }

  private unbindSuspendEvents(): void {
    // 解绑需要原始回调引用；这里选择保留注册（进程生命周期内只注册一次），
    // 只把自动重启开关关掉，避免 ArkTS 里回调引用丢失导致 off 失效。
  }

  private tryAutoRestart(why: string): void {
    const ctx: common.UIAbilityContext | undefined = this.ctx;
    if (ctx === undefined || this.restartCount >= MAX_AUTO_RESTART) {
      if (this.restartCount >= MAX_AUTO_RESTART) {
        this.emit(false, `${why}；已达自动恢复上限，请回前台手动重启`);
      }
      return;
    }
    this.restartCount++;
    // 退避：3s、6s、9s…最多 30s。第一次尽快（用户可能马上就发现断了），
    // 之后放慢，避免连续撞上系统的同一个管控策略。
    const delay: number = Math.min(RESTART_DELAY_MAX_MS, RESTART_DELAY_MS * this.restartCount);
    hilog.info(DOMAIN, TAG, 'auto restart continuous task, attempt %{public}d, delay %{public}dms',
      this.restartCount, delay);
    setTimeout(() => {
      if (this.active) {
        return;
      }
      this.start(ctx).then((ok: boolean) => {
        if (!ok) {
          this.emit(false, `${why}；第 ${this.restartCount} 次自动恢复失败，稍后继续尝试`);
        }
      });
    }, delay);
  }

  private explain(code: number): string {
    switch (code) {
      case 201:
        return '缺少后台运行权限（KEEP_BACKGROUND_RUNNING）';
      case 202:
        return '该长时任务类型不允许三方应用使用';
      case 9800005:
        return '长时任务校验未通过（系统认为没有真实数据传输）';
      case 9800006:
        return '常驻通知创建失败';
      default:
        return `长时任务申请失败 (code=${code})`;
    }
  }

  private explainCancel(reason: number): string {
    switch (reason) {
      case 1:
        return '用户手动取消了长时任务';
      case 2:
        return '系统取消了长时任务（内存/电量管控）';
      case 3:
        return '用户清掉了常驻通知，长时任务随之结束';
      case 4:
        return '系统判定数据传输低速，取消了长时任务';
      case 5:
        return '系统判定音频未使用 AVSession';
      default:
        return `长时任务被取消 (reason=${reason})`;
    }
  }
}

/** 全局单例：一条长时任务对应一个 id，重复申请会被系统拒绝 */
export const keepAlive: KeepAlive = new KeepAlive();
