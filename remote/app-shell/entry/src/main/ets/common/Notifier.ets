import notificationManager from '@ohos.notificationManager';
import wantAgent from '@ohos.app.ability.wantAgent';
import { BusinessError } from '@ohos.base';

/**
 * 系统通知：一轮任务跑完时提醒用户。
 * 通知权限是运行时申请，用户拒绝后 publish 会静默失败，不影响聊天。
 */
export class Notifier {
  private static asked: boolean = false;

  /** 首次使用时申请通知授权，并建一个会横幅提醒的通道。 */
  static async ensure(): Promise<void> {
    if (Notifier.asked) {
      return;
    }
    Notifier.asked = true;
    try {
      const on: boolean = await notificationManager.isNotificationEnabled();
      if (!on) {
        await notificationManager.requestEnableNotification();
      }
    } catch (e) {
      console.info('DSH_NOTIFY enable failed :: ' + (e as BusinessError).message);
    }
    try {
      // OTHER_TYPES 只落通知中心、不弹横幅；完成提醒要能一眼看到，用高优先级通道
      await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
    } catch (e) {
      console.info('DSH_NOTIFY slot failed :: ' + (e as BusinessError).message);
    }
  }

  /** 发一条通知，点它回到应用；同一 id 会覆盖上一条。 */
  static async done(title: string, body: string, id: number): Promise<void> {
    let agent: object | undefined = undefined;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: 'com.dsh.mobile',
            abilityName: 'EntryAbility'
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      agent = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.info('DSH_NOTIFY wantAgent failed :: ' + (e as BusinessError).message);
    }
    const req: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: body
        }
      }
    };
    if (agent !== undefined) {
      req.wantAgent = agent;
    }
    try {
      await notificationManager.publish(req);
      console.info('DSH_NOTIFY published id=' + id);
    } catch (e) {
      console.info('DSH_NOTIFY publish failed :: ' + (e as BusinessError).message);
    }
  }
}
