import { queueSync } from 'liborg_tasks_harmony.so'

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

export class NativeCoreService {
  static async recordSyncIntent(reason: string, includeCalendar: boolean, foreground: boolean): Promise<void> {
    const now = Date.now()
    const idempotencyKey = createUuid(now)
    const jobId = createUuid(now + 1)
    await queueSync(idempotencyKey, jobId, reason, includeCalendar, foreground, now)
  }
}
