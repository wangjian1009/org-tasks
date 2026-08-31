// Stores sensitive WebDAV credentials outside the app preferences database.

import { util } from '@kit.ArkTS'
import { asset } from '@kit.AssetStoreKit'

const ASSET_NOT_FOUND = 24000002

interface AssetError {
  code?: number
}

export class CredentialService {
  static async getWebDavPassword(repoId: string): Promise<string> {
    let records: asset.AssetMap[]
    try {
      records = await asset.query(passwordQuery(repoId))
    } catch (error) {
      if (errorCode(error) === ASSET_NOT_FOUND) {
        return ''
      }
      throw assetFailure('读取 WebDAV 密码失败', error)
    }
    if (records.length === 0) {
      return ''
    }
    const secret = records[0].get(asset.Tag.SECRET)
    if (!(secret instanceof Uint8Array)) {
      throw new Error('安全存储中的 WebDAV 密码格式无效')
    }
    return util.TextDecoder.create('utf-8').decodeToString(secret)
  }

  static async setWebDavPassword(repoId: string, password: string): Promise<void> {
    if (!password) {
      await clearWebDavPassword(repoId)
      return
    }

    const attributes = passwordAlias(repoId)
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

async function clearWebDavPassword(repoId: string): Promise<void> {
  try {
    await asset.remove(passwordAlias(repoId))
  } catch (error) {
    if (errorCode(error) !== ASSET_NOT_FOUND) {
      throw assetFailure('删除 WebDAV 密码失败', error)
    }
  }
}

function passwordQuery(repoId: string): asset.AssetMap {
  const query = passwordAlias(repoId)
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
  query.set(asset.Tag.RETURN_LIMIT, 1)
  return query
}

function passwordAlias(repoId: string): asset.AssetMap {
  if (!repoId.trim()) {
    throw new Error('仓库 ID 不能为空')
  }
  const attributes = new Map<asset.Tag, asset.Value>()
  attributes.set(asset.Tag.ALIAS, toBytes(`org-tasks.webdav.${repoId}.password.v1`))
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
