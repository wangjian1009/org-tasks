import { common } from '@kit.AbilityKit'
import { abilityAccessCtrl, bundleManager } from '@kit.AbilityKit'
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit'
import { reminderAgentManager } from '@kit.BackgroundTasksKit'
import { notificationManager } from '@kit.NotificationKit'
import { fileIo as fs } from '@kit.CoreFileKit'

interface ProbeResult { kind: string; code: number; message: string; before: number; after: number }
interface ProbeReport { apiVersion: number; notificationEnabled: boolean; permission: number; results: ProbeResult[] }

// 仅在独立模拟器测试进程执行；成功发布的测试提醒立即撤销，不触发响铃。
export async function probeReminders(context: common.Context): Promise<void> {
  try {
    const bundle = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
    const permission = await abilityAccessCtrl.createAtManager().checkAccessToken(bundle.appInfo.accessTokenId, 'ohos.permission.PUBLISH_AGENT_REMINDER')
    const report: ProbeReport = { apiVersion: deviceInfo.sdkApiVersion,
      notificationEnabled: await notificationManager.isNotificationEnabled(), permission, results: [] }
    const target = new Date(Date.now() + 120000)
    const requests: reminderAgentManager.ReminderRequest[] = [
      { reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_TIMER,
        triggerTimeInSeconds: 120, ringDuration: 1, title: '代理提醒验证', notificationId: 900001 } as reminderAgentManager.ReminderRequestTimer,
      { reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
        dateTime: { year: target.getFullYear(), month: target.getMonth() + 1, day: target.getDate(), hour: target.getHours(), minute: target.getMinutes() },
        ringDuration: 1, title: '代理提醒验证', notificationId: 900002 } as reminderAgentManager.ReminderRequestCalendar,
      { reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_ALARM,
        hour: target.getHours(), minute: target.getMinutes(), daysOfWeek: [],
        ringDuration: 1, title: '代理提醒验证', notificationId: 900003 } as reminderAgentManager.ReminderRequestAlarm
    ]
    for (let index = 0; index < requests.length; index++) {
      const before = (await reminderAgentManager.getAllValidReminders()).length
      const result: ProbeResult = { kind: ['timer', 'calendar', 'alarm'][index], code: 0, message: '', before, after: before }
      let id: number | undefined = undefined
      try {
        id = await reminderAgentManager.publishReminder(requests[index])
        result.after = (await reminderAgentManager.getAllValidReminders()).length
      } catch (error) { result.code = (error as BusinessError).code; result.message = (error as BusinessError).message }
      finally {
        if (id !== undefined) {
          try { await reminderAgentManager.cancelReminder(id) }
          catch (error) { result.code = (error as BusinessError).code; result.message = (error as BusinessError).message }
        }
      }
      report.results.push(result)
    }
    const file = await fs.open(`${context.filesDir}/reminder-probe.json`, fs.OpenMode.CREATE | fs.OpenMode.TRUNC | fs.OpenMode.READ_WRITE)
    try { await fs.write(file.fd, JSON.stringify(report)); await fs.fsync(file.fd) } finally { await fs.close(file) }
  } catch (error) { throw error as Error }
}
