import { localizedText } from '../ui/LocalizedText'
import { CoreTask, CoreTaskFileVersion, CoreTaskModification, CoreTaskOperation, CoreTaskOperationGroup, CoreRefileTarget } from './NativeCoreService'

class TaskOperationGroupVersionError extends Error { readonly code: string = 'invalidState' }

// 只组装宿主已选择的操作；状态、路径和文件版本的最终语义由 Core 校验。
export function taskModificationGroup(task: CoreTask, modifications: CoreTaskModification[]): CoreTaskOperationGroup {
  return { operations: [{ type: 'Modification', data: { path: task.fullPath, modifications } }],
    fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }] }
}

export function taskDeletionGroup(task: CoreTask): CoreTaskOperationGroup {
  return { operations: [{ type: 'Deletion', data: { path: task.fullPath } }],
    fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion }] }
}

export function taskMovementGroup(task: CoreTask, target: CoreRefileTarget): CoreTaskOperationGroup {
  return { operations: [{ type: 'Movement', data: { path: task.fullPath, position: { parent: target.fullPath } } }],
    fileVersions: [{ repoId: task.repoId, file: task.filePath, version: task.fileVersion },
      { repoId: target.repoId, file: target.path, version: target.fileVersion }] }
}

export function mergeTaskOperationGroups(groups: CoreTaskOperationGroup[]): CoreTaskOperationGroup {
  const versions = new Map<string, CoreTaskFileVersion>()
  const operations: CoreTaskOperation[] = []
  for (const group of groups) {
    for (const version of group.fileVersions ?? []) {
      const key = JSON.stringify([version.repoId, version.file])
      const previous = versions.get(key)
      if (previous && previous.version !== version.version) throw new TaskOperationGroupVersionError(localizedText($r('app.string.text_change_group_versions_of_the_same_document')))
      if (!previous) versions.set(key, { repoId: version.repoId, file: version.file, version: version.version })
    }
    for (const operation of group.operations) operations.push(JSON.parse(JSON.stringify(operation)) as CoreTaskOperation)
  }
  return { operations, fileVersions: Array.from(versions.values()) }
}
