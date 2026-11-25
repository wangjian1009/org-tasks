import { localizedText } from '../ui/LocalizedText'
// Stores sensitive WebDAV credentials outside the app preferences database.

import { util } from '@kit.ArkTS'
import { asset } from '@kit.AssetStoreKit'
import { RepoConfig } from '../models/OrgTask'

const ASSET_NOT_FOUND = 24000002

interface AssetError {
  code?: number
}

interface ResetCredential {
  directory: string
  url: string
  username: string
  password: string
}

export class CredentialService {
  static async getWebDavPassword(repoId: string): Promise<string> {
    return readSecret(passwordAlias(repoId))
  }

  static async preserveForReset(repo: RepoConfig): Promise<void> {
    const password = await CredentialService.getWebDavPassword(repo.id)
    if (!repo.webdavUrl || !password) return
    const saved: ResetCredential = { directory: repo.rootDirectory, url: repo.webdavUrl,
      username: repo.webdavUsername, password }
    await writeSecret(passwordAlias(repo.id, true), JSON.stringify(saved))
  }

  static async passwordForRestore(configId: string, repo: RepoConfig): Promise<string> {
    const encoded = await readSecret(passwordAlias(configId, true))
    if (!encoded) return ''
    const saved = JSON.parse(encoded) as ResetCredential
    return saved.directory === repo.rootDirectory && saved.url === repo.webdavUrl &&
      saved.username === repo.webdavUsername ? saved.password : ''
  }

  static async setWebDavPassword(repoId: string, password: string): Promise<void> {
    const attributes = passwordAlias(repoId)
    if (password) await writeSecret(attributes, password)
    else await removeSecret(attributes)
  }

  static async clearWebDavPassword(repoId: string): Promise<void> {
    await removeSecret(passwordAlias(repoId))
    await removeSecret(passwordAlias(repoId, true))
  }
}

async function readSecret(query: asset.AssetMap): Promise<string> {
  query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL)
  query.set(asset.Tag.RETURN_LIMIT, 1)
  let records: asset.AssetMap[]
  try {
    records = await asset.query(query)
  } catch (error) {
    if (errorCode(error) === ASSET_NOT_FOUND) {
      return ''
    }
    throw assetFailure(localizedText($r('app.string.text_failed_to_read_webdav_password')), error)
  }
  if (records.length === 0) {
    return ''
  }
  const secret = records[0].get(asset.Tag.SECRET)
  if (!(secret instanceof Uint8Array)) {
    throw new Error(localizedText($r('app.string.text_invalid_webdav_password_format_in_secure_storage')))
  }
  return util.TextDecoder.create('utf-8').decodeToString(secret)
}

async function writeSecret(attributes: asset.AssetMap, password: string): Promise<void> {
  attributes.set(asset.Tag.SECRET, toBytes(password))
  attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED)
  attributes.set(asset.Tag.IS_PERSISTENT, true)
  attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE)
  try {
    await asset.add(attributes)
  } catch (error) {
    throw assetFailure(localizedText($r('app.string.text_failed_to_save_webdav_password')), error)
  }
}

async function removeSecret(alias: asset.AssetMap): Promise<void> {
  try {
    await asset.remove(alias)
  } catch (error) {
    if (errorCode(error) !== ASSET_NOT_FOUND) {
      throw assetFailure(localizedText($r('app.string.text_failed_to_delete_webdav_password')), error)
    }
  }
}

function passwordAlias(repoId: string, reset: boolean = false): asset.AssetMap {
  if (!repoId.trim()) {
    throw new Error(localizedText($r('app.string.text_repository_id_cannot_be_empty')))
  }
  const attributes = new Map<asset.Tag, asset.Value>()
  const purpose = reset ? 'reset' : 'password'
  attributes.set(asset.Tag.ALIAS, toBytes(`org-tasks.webdav.${repoId}.${purpose}.v1`))
  return attributes
}

function toBytes(value: string): Uint8Array {
  return util.TextEncoder.create().encodeInto(value)
}

function errorCode(error: Object): number {
  return (error as AssetError).code || 0
}

function assetFailure(action: string, error: Object): Error {
  const code = errorCode(error)
  return new Error(code ? localizedText($r('app.string.text_error_code_2'), String(action), String(code)) : action)
}
