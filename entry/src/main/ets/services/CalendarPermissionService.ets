import { abilityAccessCtrl, bundleManager, Context, Permissions } from '@kit.AbilityKit'

const PERMISSIONS: Permissions[] = ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']
export type CalendarPermissionState = 'enabled' | 'disabled'

// 后台只读权限状态；授权窗口仅由设置页的用户操作打开。
export class CalendarPermissionService {
  private static tokenId: number | undefined = undefined

  static async state(): Promise<CalendarPermissionState> {
    try {
      if (CalendarPermissionService.tokenId === undefined) {
        const info = await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION)
        CalendarPermissionService.tokenId = info.appInfo.accessTokenId
      }
      const manager = abilityAccessCtrl.createAtManager()
      for (const permission of PERMISSIONS) {
        if (await manager.checkAccessToken(CalendarPermissionService.tokenId, permission) !== 0) return 'disabled'
      }
      return 'enabled'

    } catch (error) { throw error as Error }
  }

  static async request(context: Context): Promise<boolean> {
    try {
      if (await CalendarPermissionService.state() === 'enabled') return true
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context, PERMISSIONS)
      return result.authResults.length === PERMISSIONS.length && result.authResults.every(value => value === 0)

    } catch (error) { throw error as Error }
  }

  static async manage(context: Context): Promise<void> {
    try {
      await abilityAccessCtrl.createAtManager().requestPermissionOnSetting(context, PERMISSIONS)

    } catch (error) { throw error as Error }
  }
}
