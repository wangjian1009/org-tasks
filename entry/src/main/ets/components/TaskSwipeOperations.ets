import { DataSet } from '../services/DataSet'
import { CoreTaskOperationGroup } from '../services/NativeCoreService'
import { mergeTaskOperationGroups } from '../services/TaskOperationGroups'

// 单条滑动和页面批量操作共用一次提交；operationId 由数据集统一分配。
export class TaskSwipeOperations {
  static async submit(dataSet: DataSet, groups: CoreTaskOperationGroup[], allowed: () => boolean = () => true): Promise<void> {
    if (!allowed()) throw new Error('操作已取消')
    const group = mergeTaskOperationGroups(groups)
    if (!group.operations.length) return
    await dataSet.submitOperationGroup(group, allowed)
  }
}
