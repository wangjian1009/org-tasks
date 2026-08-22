// Stores sensitive WebDAV credentials outside the app preferences database.

import { Context } from '@kit.AbilityKit'
import { preferences } from '@kit.ArkData'
import { util } from '@kit.ArkTS'
import { asset } from '@kit.AssetStoreKit'

const PREF_NAME = 'org_tasks_config'
const LEGACY_PASSWORD_KEY = 'webdavPassword'
const PASSWORD_ALIAS = 'org-tasks.webdav.password.v1'
const ASSET_NOT_FOUND = 24000002

interface AssetError {
  code?: number
}

export class CredentialService {
  static async getWebDavPassword(context: Context): Promise<string> {
    let records: asset.AssetMap[]
    try {
      records = await asset.query(passwordQuery())
    } catch (error) {
      if (errorCode(error) === ASSET_NOT_FOUND) {
        return migrateLegacyPassword(context)
      }
      throw assetFailure('读取 WebDAV 密码失败', error)
    }
    if (records.length === 0) {
      return migrateLegacyPassword(context)
    }
    const secret = records[0].get(asset.Tag.SECRET)
    if (!(secret instanceof Uint8Array)) {
      throw new Error('安全存储中的 WebDAV 密码格式无效')
    }
    return util.TextDecoder.create('utf-8').decodeToString(secret)
  }

  static async setWebDavPassword(password: string): Promise<void> {
    if (!password) {
      await clearWebDavPassword()
      return
    }

    const attributes = passwordAlias()
    attributes.set(asset.Tag.SECRET, toBytes(password))
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
    attributes.set(asset.Tag.IS_PERSISTENT, true)
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE)
    try {
      await asset.add(attributes)
    } catch (error) {
      throw assetFailure('保存 WebDAV 密码失败', error)
    }
  }
}

async function migrateLegacyPassword(context: Context): Promise<string> {
  const store = await preferences.getPreferences(context, PREF_NAME)
  const legacyPassword = await store.get(LEGACY_PASSWORD_KEY, '') as string
  if (!legacyPassword) return ''

  await CredentialService.setWebDavPassword(legacyPassword)
  await store.delete(LEGACY_PASSWORD_KEY)
  await store.flush()
  return legacyPassword
}

async function clearWebDavPassword(): Promise<void> {
  try {
    await asset.remove(passwordAlias())
  } catch (error) {
    if (errorCode(error) !== ASSET_NOT_FOUND) {
      throw assetFailure('删除 WebDAV 密码失败', error)
    }
  }
}

function passwordQuery(): asset.AssetMap {
  const query = passwordAlias()
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
  query.set(asset.Tag.RETURN_LIMIT, 1)
  return query
}

function passwordAlias(): asset.AssetMap {
  const attributes = new Map<asset.Tag, asset.Value>()
  attributes.set(asset.Tag.ALIAS, toBytes(PASSWORD_ALIAS))
  return attributes
}

function toBytes(value: string): Uint8Array {
  return util.TextEncoder.create().encode(value)
}

function errorCode(error: Object): number {
  return (error as AssetError).code || 0
}

function assetFailure(action: string, error: Object): Error {
  const code = errorCode(error)
  return new Error(code ? `${action}（错误码 ${code}）` : action)
}
