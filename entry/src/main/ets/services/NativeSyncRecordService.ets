import { initialize, recordSync } from 'liborg_tasks_harmony.so'

function createUuid(seed: number): string {
  let value = ''
  let state = seed ^ Math.floor(Math.random() * 0x7fffffff)
  const template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
  for (let index = 0; index < template.length; index++) {
    const character = template.charAt(index)
    if (character === 'x' || character === 'y') {
      state = (state * 1664525 + 1013904223) >>> 0
      const nibble = state & 0x0f
      value += (character === 'x' ? nibble : (nibble & 0x03) | 0x08).toString(16)
    } else {
      value += character
    }
  }
  return value
}

export class NativeSyncRecordService {
  static async recordSyncResult(
    dataDir: string,
    repoId: string,
    startedAt: number,
    succeeded: boolean
  ): Promise<void> {
    if (!repoId.trim()) {
      throw new Error('仓库 ID 不能为空')
    }
    await initialize(dataDir)
    const finishedAt = Date.now()
    await recordSync(
      repoId,
      createUuid(finishedAt),
      startedAt,
      finishedAt,
      succeeded
    )
  }
}
