import { executeCore } from 'liborg_tasks_harmony.so'

export interface CoreRepositoryFile {
  path: string
  source: string
  byte_length: number
}

export interface CoreRepositorySnapshot {
  id: string
  files: CoreRepositoryFile[]
}

export interface CoreSyncSnapshot {
  id: string
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'
  started_at: number
  finished_at: number | null
  files: number
}

export interface CoreBridgeResponse {
  repository: CoreRepositorySnapshot
  sync: CoreSyncSnapshot | null
}

export type CoreBridgeRequest =
  | {
      action: 'load_repository'
      root_directory: string
    }
  | {
      action: 'sync_webdav'
      root_directory: string
      webdav_url: string
      username: string
      password: string
      started_at: number
    }

// ArkTS 仅传递 core 定义的结构化请求与响应，不解释 org 内容或同步规则。
export class NativeCoreService {
  static async execute(request: CoreBridgeRequest): Promise<CoreBridgeResponse> {
    const response = await executeCore(JSON.stringify(request))
    return JSON.parse(response) as CoreBridgeResponse
  }
}
