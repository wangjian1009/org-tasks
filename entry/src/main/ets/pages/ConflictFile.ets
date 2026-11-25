import { localizedText } from '../ui/LocalizedText'
import { showDangerousConfirmation } from '../components/controls/DangerousConfirmation'
import { PageNavigator } from '../services/PageNavigator'
import { AppShell } from '../components/AppShell'
import { EmptyState } from '../components/controls/EmptyState'
import { OrgFileConflictView, OrgFileConflictNavigation, OrgConflictCard } from '../components/OrgFileConflictView'
import { AppConfigService } from '../services/AppConfigService'
import { CoreBridgeError, CoreConflictPreview, CoreConflictPreviewChanges, CoreConflictPreviewProjection, CoreConflictTarget, CoreFileConflict,
  CoreOrgFile, CoreTaskOperation, CoreTaskOperationGroup, CoreTitlePart, CoreWorkspace, NativeCoreService, coreErrorMessage } from '../services/NativeCoreService'
import { UiColor, repositoryLabel } from '../ui/Theme'
import { ConflictTargetNode, ConflictTargetRow, conflictTargetTree, conflictTargetRows } from '../ui/ConflictTargetTree'

interface ConflictParams { repoId: string; coreRepoId?: string; path: string }

@Entry
@Component
struct ConflictFile {
  @State file: CoreOrgFile | undefined = undefined
  @State baseFile: CoreOrgFile | undefined = undefined
  @State previewFile: CoreOrgFile | undefined = undefined
  @State conflicts: CoreFileConflict[] = []
  @State changes: CoreConflictPreviewChanges | undefined = undefined
  @State projection: CoreConflictPreviewProjection | undefined = undefined
  @State beforeText: string = ''
  @State afterText: string = ''
  @State comparisonLoading: boolean = false
  @State html: string = ''
  @State path: string = ''
  @State title: string = ''
  @State titleParts: CoreTitlePart[] = []
  @State fileContext: string = ''
  @State loading: boolean = true
  @State saving: boolean = false
  @State message: string = ''
  @State stale: boolean = false
  @State drawerOpen: boolean = false
  @State targetsVisible: boolean = false
  @State targetRoot: ConflictTargetNode | undefined = undefined
  @State expandedTargetKeys: string[] = []
  @State detailsExpanded: boolean = true
  @State selectedId: string = ''
  @State stagedAction: string = ''
  @State manuallyEdited: boolean = false
  @State renderRevision: number = 0
  private navigation: OrgFileConflictNavigation = new OrgFileConflictNavigation()
  private pendingGroup: CoreTaskOperationGroup | undefined = undefined
  private preview: CoreConflictPreview | undefined = undefined
  private workspace: CoreWorkspace | undefined = undefined
  private requestId: number = 0
  private coreRepoId: string = ''
  private configRepoId: string = ''
  private sourceRootDirectory: string = ''
  private initialized: boolean = false
  private leaving: boolean = false
  @State selectedTarget: CoreConflictTarget | undefined = undefined
  private restoredPosition: number | undefined = undefined

  private stopExternalGuard: (() => void) | undefined = undefined
  onPageHide(): void { this.stopExternalGuard?.(); this.stopExternalGuard = undefined }
  onPageShow() {
    this.stopExternalGuard?.()
    this.stopExternalGuard = PageNavigator.shared.watchExternalLeaveGuard((): boolean =>
      !this.loading && !this.saving && !this.manuallyEdited && !this.pendingGroup && !this.stagedAction)
    if (!this.initialized) this.load()
    else if (this.preview) this.refreshPreview()
    else this.load()
  }
  aboutToDisappear() {
    this.stopExternalGuard?.()
    this.requestId++
    const preview = this.preview
    if (preview) preview.discard().catch((): void => {})
  }
  onBackPress(): boolean {
    if (this.saving) return true
    if (this.targetsVisible) { this.targetsVisible = false; return true }
    if (this.navigation.closePanel()) return true
    this.exit()
    return true
  }

  async load(selectFirst: boolean = true) {
    const request = ++this.requestId
    this.loading = true
    this.message = ''
    let createdPreview: CoreConflictPreview | undefined = undefined
    try {
      const params = this.getUIContext().getRouter().getParams() as ConflictParams
      const context = this.getUIContext().getHostContext()!
      const config = await AppConfigService.load(context, false)
      const repository = config.repos.find(repo => repo.id === params.repoId)
      if (!repository) throw new Error(localizedText($r('app.string.text_this_repository_does_not_exist')))
      const workspace = await NativeCoreService.workspaceFor(config.repos, config.todoDefaults, config.coreSettings)
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      if (params.coreRepoId !== undefined && repo.id !== params.coreRepoId) {
        throw new Error(localizedText($r('app.string.text_the_repository_has_changed_reopen_it')))
      }
      await workspace.setPreviewRoot(`${context.cacheDir}/org-conflict-previews`)
      const file = await repo.file(params.path)
      let conflicts = file.conflicts()
      let baseFile = file
      let previewFile: CoreOrgFile | undefined = undefined
      if (conflicts.length > 0) {
        createdPreview = await workspace.createConflictPreview({ file: file.fullPath, conflictId: conflicts[0].id, sourceVersion: file.fileVersion })
        baseFile = await createdPreview.sourceFile()
        previewFile = await createdPreview.file()
        conflicts = await createdPreview.conflicts()
      }
      if (request !== this.requestId) { if (createdPreview) await createdPreview.discard(); return }
      this.workspace = workspace
      this.coreRepoId = repo.id
      this.configRepoId = repository.id
      this.sourceRootDirectory = repository.rootDirectory
      this.path = params.path
      this.title = file.title() || this.path
      this.titleParts = file.titleParts()
      this.fileContext = `${repositoryLabel(repository)} / ${params.path}`
      this.file = file
      conflicts.sort((a: CoreFileConflict, b: CoreFileConflict): number =>
        (a.displayAnchor?.start.byte_offset ?? Number.MAX_SAFE_INTEGER) - (b.displayAnchor?.start.byte_offset ?? Number.MAX_SAFE_INTEGER))
      this.conflicts = conflicts
      this.preview = createdPreview
      this.baseFile = baseFile
      this.previewFile = previewFile
      this.changes = undefined
      this.projection = undefined
      this.beforeText = ''
      this.afterText = ''
      this.selectedTarget = undefined
      this.targetRoot = undefined
      this.expandedTargetKeys = []
      this.targetsVisible = false
      this.manuallyEdited = false
      this.stale = false
      this.selectedId = ''
      this.stagedAction = ''
      this.initialized = true
      this.present(baseFile)
      if (conflicts.length > 0) this.selectedId = conflicts[0].id

    } catch (e) {
      if (createdPreview) await createdPreview.discard().catch((): void => {})
      if (request === this.requestId) this.message = localizedText($r('app.string.text_failed_to_read_conflict_file'), String(coreErrorMessage(e as CoreBridgeError)))
    } finally { if (request === this.requestId) this.loading = false }
  }

  present(file: CoreOrgFile) {
    this.html = file.renderHtml()
    this.renderRevision++
  }

  presentProjection() {
    if (!this.projection) return
    this.html = this.projection.renderedHtml
    this.renderRevision++
  }

  async readProjection(target?: CoreConflictTarget) {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.selectedId) return
    const request = this.requestId
    const conflictId = this.selectedId
    this.comparisonLoading = true
    try {
      const projection = await preview.project({ conflictId, previewVersion: file.fileVersion, target })
      if (request !== this.requestId || preview.id !== this.preview?.id || conflictId !== this.selectedId) return
      if (projection.conflictId !== conflictId || projection.workingVersion !== file.fileVersion) throw new Error(localizedText($r('app.string.text_discrepancies_have_lapsed_please_try_again')))
      this.projection = projection
      this.changes = projection.changes
      this.beforeText = projection.beforeText
      this.afterText = projection.afterText
      // 只在卡片操作需要目标时打开选择器，定位不改变正文。
    } finally { if (request === this.requestId && conflictId === this.selectedId) this.comparisonLoading = false }
  }

  async retryPreview() {
    if (this.saving) return
    this.saving = true
    this.message = ''
    try {
      if (this.stagedAction) await this.refreshPreview()
      else await this.readProjection(this.selectedTarget)
    } catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_failed_to_read_difference'))) }
    finally { this.saving = false }
  }

  summaryText(before: boolean): string {
    if (this.comparisonLoading) return localizedText($r('app.string.text_reading'))
    if (!this.stagedAction && !this.projection) return localizedText($r('app.string.text_discrepancies_read_failed_please_try_again'))
    if (!this.stagedAction && this.projection?.status === 'unavailable') return before ? localizedText($r('app.string.text_keep_the_contents_of_the_current_document')) : localizedText($r('app.string.text_candidate_is_incomplete_only_the_current_one'))
    if (!this.stagedAction && this.projection?.status === 'targetRequired') {
      return before ? localizedText($r('app.string.text_to_be_compared_after_selection_of_target')) : this.afterText.trim() || localizedText($r('app.string.text_delete_intent_locally_to_select_target'))
    }
    if (this.mainChangeCount() === 0) return this.stagedAction === 'discard' ? localizedText($r('app.string.text_the_text_remains_unchanged')) : localizedText($r('app.string.text_same_as_current_content'))
    return (before ? this.beforeText : this.afterText).trim() || (before ? localizedText($r('app.string.text_there_s_nothing_here')) : localizedText($r('app.string.text_this_will_be_deleted')))
  }

  selectedConflict(): CoreFileConflict | undefined { return this.conflicts.find(item => item.id === this.selectedId) }
  mainChangeCount(): number { return this.changes?.changes.filter(change => change.area === 'main').length ?? 0 }
  canApply(): boolean {
    return !this.saving && !this.stale && !this.message && !!this.previewFile && !!this.stagedAction &&
      this.changes?.previewVersion === this.previewFile.fileVersion
  }

  reasonLabel(reason: string): string {
    switch (reason) {
      case 'modify': return localizedText($r('app.string.text_locally_and_at_the_same_time_the'))
      case 'create': return localizedText($r('app.string.text_locally_add_this_node_select_the_place'))
      case 'delete': return localizedText($r('app.string.text_this_node_has_been_deleted_locally_and'))
      case 'modify-missing': return localizedText($r('app.string.text_the_original_node_has_disappeared_and_local'))
      case 'missing-parent': return localizedText($r('app.string.text_the_parent_node_has_disappeared_select_the'))
      case 'reorder': return localizedText($r('app.string.text_the_order_of_nodes_has_been_adjusted'))
      case 'structure': return localizedText($r('app.string.text_the_document_structure_is_in_conflict_and'))
      case 'header': return localizedText($r('app.string.text_there_are_different_changes_to_the_document'))
      default: return localizedText($r('app.string.text_there_is_a_conflict_of_content_here'))
    }
  }

  conflictCards(): OrgConflictCard[] {
    return this.conflicts.map((conflict: CoreFileConflict): OrgConflictCard => {
      const kind = conflict.reason === 'delete' ? 'delete' :
        ['create', 'missing-parent', 'modify-missing'].includes(conflict.reason) ? 'create' : 'modify'
      return { id: conflict.id, title: conflict.title, kind,
        kindLabel: kind === 'delete' ? localizedText($r('app.string.text_delete')) : kind === 'create' ? localizedText($r('app.string.text_add_3')) : localizedText($r('app.string.text_edit_2')),
        applyLabel: conflict.reason === 'delete' ? localizedText($r('app.string.text_delete')) : kind === 'create' ? localizedText($r('app.string.text_insert')) : localizedText($r('app.string.text_apply')),
        content: conflict.candidateContent, html: conflict.candidateHtml,
        anchorStart: conflict.displayAnchor?.start.byte_offset ?? -1, atTarget: conflict.displayAtTarget,
        available: conflict.availableActions.includes('useLocal') }
    })
  }

  selectConflict(conflict: CoreFileConflict) {
    if (this.saving || this.stale || this.pendingGroup) return
    if (this.selectedId === conflict.id) { this.navigation.focusConflictCard(conflict.id); return }
    if (this.stagedAction || this.manuallyEdited) {
      this.confirmAbandon((): void => { this.prepare(conflict, '') })
      return
    }
    this.selectedId = conflict.id
    this.selectedTarget = undefined
    this.projection = undefined
    this.targetRoot = undefined
    this.navigation.focusConflictCard(conflict.id)
  }

  async activateCard(id: string, action: string) {
    if (this.saving || this.comparisonLoading || this.stale || this.pendingGroup) return
    const conflict = this.conflicts.find(item => item.id === id)
    if (!conflict) return
    if (this.selectedId !== id) this.selectConflict(conflict)
    if (this.selectedId !== id) return
    if (action === 'focus') { this.selectedId = id; return }
    if (action === 'discard') { await this.discardChoice(); return }
    try {
      await this.applyChoice()
    } catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_reading_candidate_failed'))) }
  }

  selectAdjacent(delta: number) {
    if (this.saving || this.stale || this.pendingGroup || this.conflicts.length === 0) return
    const current = this.conflicts.findIndex(item => item.id === this.selectedId)
    const index = current < 0 ? delta < 0 ? this.conflicts.length - 1 : 0 :
      (current + delta + this.conflicts.length) % this.conflicts.length
    this.selectConflict(this.conflicts[index])
  }

  confirmAbandon(action: () => void) {
    if (!this.manuallyEdited) { action(); return }
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_giving_up_unapplied_adjustments')),
      message: localizedText($r('app.string.text_the_manual_adjustments_are_kept_in_the')),
      confirmLabel: localizedText($r('app.string.text_waiver_of_adjustment')), onConfirm: action })
  }

  async prepare(conflict: CoreFileConflict, action: string, target?: CoreConflictTarget) {
    if (!this.workspace || !this.file || this.saving) return
    const request = ++this.requestId
    const reusable = this.preview && !this.stagedAction && !this.manuallyEdited && !this.pendingGroup && !this.stale ? this.preview : undefined
    this.saving = true
    this.comparisonLoading = true
    this.message = ''
    this.stale = false
    this.changes = undefined
    this.projection = undefined
    this.beforeText = ''
    this.afterText = ''
    this.selectedId = conflict.id
    this.selectedTarget = target
    this.targetsVisible = false
    this.targetRoot = undefined
    this.expandedTargetKeys = []
    this.detailsExpanded = true
    this.html = ''
    this.renderRevision++
    this.stagedAction = ''
    this.manuallyEdited = false
    this.pendingGroup = undefined
    try {
      const preview = reusable ?? await this.workspace.createConflictPreview({ file: this.file.fullPath,
        conflictId: conflict.id, sourceVersion: this.file.fileVersion })
      if (request !== this.requestId) { await preview.discard(); return }
      this.preview = preview
      this.selectedId = conflict.id
      const copied = await preview.file()
      const base = await preview.sourceFile()
      const pending = await preview.conflicts()
      if (request !== this.requestId || preview.id !== this.preview?.id) return
      this.baseFile = base
      this.previewFile = copied
      this.present(copied)
      const copiedConflict = pending.find(item => item.id === conflict.id)
      if (!copiedConflict) throw new Error(localizedText($r('app.string.text_conflict_point_has_changed_read_again')))
      if (action === 'discard') await this.stage('discard')
      else if (action === 'useLocal') {
        if (target || copiedConflict.suggestedTarget) await this.stage('useLocal', target ?? copiedConflict.suggestedTarget!)
        else { await this.readProjection(); this.openTargets() }
      } else await this.readProjection()
    } catch (e) {
      if (request !== this.requestId) return
      this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_failed_to_create_preview')))
      // 失败可能发生在替换旧槽位之后，不继续使用旧的文件投影。
      if (this.preview) {
        try { this.previewFile = await this.preview.file() } catch (_) { this.preview = undefined; this.previewFile = undefined }
      }
    } finally { if (request === this.requestId) { this.saving = false; this.comparisonLoading = false } }
  }

  async stage(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.workspace) return
    const group: CoreTaskOperationGroup = {
      operations: [{ type: 'ConfilictSelection', data: { path: file.fullPath, id: this.selectedId, action, target } }],
      fileVersions: [{ repoId: file.repoId, file: file.path, version: file.fileVersion }]
    }
    await this.workspace.executeTaskOperations(group)
    this.stagedAction = action
    await this.refreshPreview(false)
  }

  applyLabel(): string {
    switch (this.selectedConflict()?.reason ?? '') {
      case 'create': return localizedText($r('app.string.text_insert'))
      case 'delete': return localizedText($r('app.string.text_delete'))
      case 'modify-missing':
      case 'missing-parent': return localizedText($r('app.string.text_placement'))
      case 'reorder':
      case 'structure': return localizedText($r('app.string.text_replace_main_tree'))
      case 'header': return localizedText($r('app.string.text_use_file_properties'))
      default: return localizedText($r('app.string.text_apply'))
    }
  }

  async applyChoice() {
    if (this.saving || this.stale || this.pendingGroup) return
    const conflict = this.selectedConflict()
    if (!conflict?.availableActions.includes('useLocal') || this.comparisonLoading || this.message) return
    if (!this.stagedAction && !this.projection) {
      try { await this.readProjection(this.selectedTarget) }
      catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_reading_candidate_failed'))); return }
    }
    if (!this.stagedAction && this.projection?.status !== 'ready') { this.openTargets(); return }
    if (['reorder', 'structure'].includes(conflict.reason)) {
      showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_replace_the_main_tree_with_local_content')),
        message: localizedText($r('app.string.text_the_full_local_content_of_the_preview')),
        confirmLabel: localizedText($r('app.string.text_replace_main_tree')), onConfirm: (): void => { this.submitChoice('useLocal', { type: 'replaceMain' }) } })
    } else await this.submitChoice('useLocal', this.selectedTarget)
  }

  async discardChoice() {
    if (this.saving || this.stale || this.pendingGroup) return
    await this.submitChoice('discard')
  }

  async submitChoice(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    if (this.saving || this.stale || this.pendingGroup || !this.previewFile || !this.selectedConflict()) return
    if (this.stagedAction && this.stagedAction !== action) {
      this.confirmAbandon((): void => { this.rebuildAndSubmit(action, target) })
      return
    }
    this.saving = true
    this.message = ''
    try { if (!this.stagedAction) await this.stage(action, target) }
    catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_failure_to_address_conflict'))) }
    finally { this.saving = false }
    if (!this.message) await this.applyPreview()
  }

  async rebuildAndSubmit(action: 'discard' | 'useLocal', target?: CoreConflictTarget) {
    const conflict = this.selectedConflict()
    if (!conflict) return
    await this.prepare(conflict, '')
    if (!this.message) await this.submitChoice(action, target)
  }

  openTargets() {
    const file = this.previewFile
    const conflict = this.selectedConflict()
    if (!file || !conflict || this.stale || this.pendingGroup) return
    if (!this.targetRoot) {
      this.targetRoot = conflictTargetTree(file, conflict.reason)
      this.expandedTargetKeys = [this.targetRoot.key, ...this.targetRoot.children.map(node => node.key)]
    }
    this.targetsVisible = true

  }

  targetRows(): ConflictTargetRow[] {
    return this.targetRoot ? conflictTargetRows(this.targetRoot, this.expandedTargetKeys) : []
  }

  toggleTargetBranch(row: ConflictTargetRow) {
    if (this.saving || !row.branch) return
    this.expandedTargetKeys = row.expanded ? this.expandedTargetKeys.filter(key => key !== row.key) :
      [...this.expandedTargetKeys, row.key]
  }

  selectedTargetLabel(): string {
    const target = this.selectedTarget ?? this.selectedConflict()?.suggestedTarget
    if (!target) return localizedText($r('app.string.text_select_placement'))
    if (target.type === 'existing') return target.data.titles.join(' / ')
    if (target.type === 'insert') return target.data.after ? localizedText($r('app.string.text_after'), String(target.data.after.titles.join(' / '))) :
      target.data.parent.titles.length ? localizedText($r('app.string.text_next'), String(target.data.parent.titles.join(' / '))) : localizedText($r('app.string.text_first_title_in_the_file'))
    return this.selectedConflict()?.reason === 'header' ? localizedText($r('app.string.text_current_file_properties')) : localizedText($r('app.string.text_full_main_tree'))
  }

  async chooseTarget(row: ConflictTargetRow) {
    if (this.saving || !row.target) return
    const request = this.requestId
    this.saving = true
    this.message = ''
    try {
      await this.readProjection(row.target)
      if (request === this.requestId) {
        this.selectedTarget = row.target
        this.targetsVisible = false
      }
    }
    catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_couldn_t_apply_to_this_target'))) }
    finally { this.saving = false }
  }

  async refreshPreview(checkSource: boolean = true) {
    const preview = this.preview
    if (!preview || this.pendingGroup) return
    const request = this.requestId
    try {
      const file = await preview.file()
      const changes = await preview.changes()
      if (request !== this.requestId || preview.id !== this.preview?.id) return
      if (changes.previewVersion !== file.fileVersion) throw new Error(localizedText($r('app.string.text_preview_is_changing_read_again')))
      if (this.previewFile && file.fileVersion !== this.previewFile.fileVersion && checkSource) this.manuallyEdited = true
      this.previewFile = file
      if (!this.stagedAction && this.selectedId) await this.readProjection(this.selectedTarget)
      else {
        this.changes = changes
        this.beforeText = changes.changes.map(change => change.lines.filter(line => line.kind === 'removed').map(line => line.text).join('')).join('\n')
        this.afterText = changes.changes.map(change => change.lines.filter(line => line.kind === 'added').map(line => line.text).join('')).join('\n')
        this.present(file)
      }
      if (checkSource && this.workspace) {
        const current = await this.workspace.fileAt(preview.sourcePath)
        if (request === this.requestId && current.fileVersion !== preview.sourceVersion) this.stale = true
      }
    } catch (e) { if (request === this.requestId) this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_reading_preview_failed'))) }
  }

  async applyPreview() {
    const preview = this.preview
    const file = this.previewFile
    if (!preview || !file || !this.canApply()) return
    this.saving = true
    this.message = ''
    let committed = false
    try {
      const position = await this.navigation.capturePosition()
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find(item => item.id === this.configRepoId)
      if (!repository) throw new Error(localizedText($r('app.string.text_this_repository_does_not_exist')))
      if (repository.rootDirectory !== this.sourceRootDirectory) throw new Error(localizedText($r('app.string.text_reread_repository_directory_change')))
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      if (repo.id !== this.coreRepoId) throw new Error(localizedText($r('app.string.text_the_repository_has_changed_read_it_again')))
      const group = this.pendingGroup ?? await preview.finish({ previewVersion: file.fileVersion })
      this.pendingGroup = group

      if (!this.workspace) throw new Error(localizedText($r('app.string.text_workspace_expired')))
      await this.workspace.executeTaskOperations(group)
      this.pendingGroup = undefined
      committed = true
      this.preview = undefined
      this.manuallyEdited = false
      this.restoredPosition = position
      await this.load(false)
    } catch (e) {
      this.handleError(e as CoreBridgeError, committed ? localizedText($r('app.string.text_applyd_reread_failed')) : localizedText($r('app.string.text_application_failed')))
      if (!committed && this.workspace) {
        try { const current = await this.workspace.fileAt(preview.sourcePath); if (current.fileVersion !== preview.sourceVersion) this.stale = true }
        catch (_) { this.stale = true }
      }
    }
    finally { this.saving = false }
  }

  recreate() {
    if (this.saving) return
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_recreate_preview')), message: localizedText($r('app.string.text_discards_the_trade_offs_and_manual_adjustments')),
      confirmLabel: localizedText($r('app.string.text_recreate')), onConfirm: (): void => { this.reloadDiscardingPreview() } })
  }

  async reloadDiscardingPreview() {
    this.saving = true
    try { if (this.preview) await this.preview.discard(); this.preview = undefined; this.pendingGroup = undefined; this.manuallyEdited = false; await this.load() }
    catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_reread_failed'))) }
    finally { this.saving = false }
  }

  handleError(error: CoreBridgeError, prefix: string) {
    if (error.code === 'sourceVersionMismatch') this.stale = true
    this.message = `${prefix}：${coreErrorMessage(error)}`
  }

  confirmDiscard() {
    if (this.saving || !this.file || this.file.conflictIds.length === 0) return
    showDangerousConfirmation(this.getUIContext(), { title: localizedText($r('app.string.text_discarding_all_conflicts')),
      message: localizedText($r('app.string.text_the_conflict_point_in_will_be_removed'), String(this.path), String(this.file.conflictIds.length)),
      confirmLabel: localizedText($r('app.string.text_discard_all')), onConfirm: (): void => { this.discardAll() } })
  }

  async discardAll() {
    const file = this.file
    if (!file || file.conflictIds.length === 0 || this.saving) return
    this.saving = true
    this.message = ''
    try {
      const config = await AppConfigService.load(this.getUIContext().getHostContext()!, false)
      const repository = config.repos.find(item => item.id === this.configRepoId)
      if (!repository) throw new Error(localizedText($r('app.string.text_this_repository_does_not_exist')))
      if (repository.rootDirectory !== this.sourceRootDirectory) throw new Error(localizedText($r('app.string.text_reread_repository_directory_change')))
      const repo = await NativeCoreService.repository(config.repos, repository, config.todoDefaults, config.coreSettings)
      if (repo.id !== this.coreRepoId) throw new Error(localizedText($r('app.string.text_the_repository_has_changed_read_it_again')))
      if (this.preview) await this.preview.discard()
      this.preview = undefined
      await NativeCoreService.executeTaskOperations(config.repos, {
        operations: file.conflictIds.map((id: string): CoreTaskOperation => ({ type: 'ConfilictSelection', data: { path: file.fullPath, id, action: 'discard' } })),
        fileVersions: [{ repoId: this.coreRepoId, file: this.path, version: file.fileVersion }]
      }, config.todoDefaults, config.coreSettings)
      this.manuallyEdited = false
      await this.load()
    } catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_discard_failed'))) }
    finally { this.saving = false }
  }

  exit() {
    if (this.saving || this.leaving) return
    this.confirmAbandon((): void => { this.leave() })
  }
  async leave() {
    if (this.saving || this.leaving) return
    this.leaving = true
    this.requestId++
    try { if (this.preview) await this.preview.discard(); this.preview = undefined; await PageNavigator.shared.back(this.getUIContext()) }
    catch (e) { this.handleError(e as CoreBridgeError, localizedText($r('app.string.text_failed_to_return'))); this.leaving = false }
  }

  @Builder
  targetTree() {
    Column({ space: 8 }) {
      Text(['modify', 'delete'].includes(this.selectedConflict()?.reason ?? '') ? localizedText($r('app.string.text_select_the_corresponding_node')) : localizedText($r('app.string.text_select_placement')))
        .fontSize(15).fontColor(UiColor.text).width('100%').padding({ right: 48 })
      Text($r('app.string.text_expand_parent_node_tap_on_the_title')).fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ right: 48 })
      Scroll() {
        Column() {
          ForEach(this.targetRows(), (row: ConflictTargetRow) => {
            Row({ space: 4 }) {
              Button(row.branch ? row.expanded ? '⌄' : '›' : '└').fontSize(16).width(36).height(44)
                .backgroundColor(Color.Transparent).fontColor(UiColor.secondary).enabled(row.branch && !this.saving)
                .accessibilityText(`${row.expanded ? localizedText($r('app.string.text_collapse')) : localizedText($r('app.string.text_expand'))} ${row.label}`)
                .onClick((): void => { this.toggleTargetBranch(row) })
              Text(row.label).fontSize(14).fontColor(row.target ? UiColor.text : UiColor.secondary).layoutWeight(1)
                .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
                .onClick((): void => { this.chooseTarget(row) }).enabled(!!row.target && !this.saving)
                .accessibilityText(`${row.label}，${row.target?.type === 'insert' && !row.key.endsWith(':after') ? localizedText($r('app.string.text_first_at_this_node')) : localizedText($r('app.string.text_select_this_target'))}`)
            }.width('100%').constraintSize({ minHeight: 44 }).padding({ left: Math.min(row.depth, 8) * 16, right: 4 })
          }, (row: ConflictTargetRow) => row.key)
        }.width('100%')
      }.width('100%').height(Math.min(220, this.targetRows().length * 44)).align(Alignment.TopStart)
    }.width('100%').padding(12).backgroundColor(UiColor.container).borderRadius(12)
  }

  build() {
    Column() {
      AppShell({ title: this.title || this.path || localizedText($r('app.string.text_documentation')), titleParts: this.titleParts, titleIcon: $r('app.media.ui_conflict_resolve'),
        back: true, drawerOpen: $drawerOpen, busy: this.saving,
        backAction: (): void => { this.exit() },
        actionIcon: $r('app.media.ui_more'), actionLabel: this.conflicts.length > 0 ? localizedText($r('app.string.text_more_operations')) : '',
        actionMenuItems: [{ title: localizedText($r('app.string.text_drop_all_conflicts')), dangerous: true, action: (): void => { this.confirmDiscard() } },
          { title: localizedText($r('app.string.text_document_directory')), action: (): void => { this.navigation.openOutline() } }] }) {
        Column() {
          if (this.loading) {
            EmptyState({ title: localizedText($r('app.string.text_reading_conflict_files')), busy: true })
          } else if (!this.file) {
            EmptyState({ title: localizedText($r('app.string.text_can_t_handle_the_conflict')), detail: this.message, actionLabel: localizedText($r('app.string.text_reread')), action: (): void => { this.load() } })
          } else {
            Text(this.fileContext).fontSize(12).fontColor(UiColor.secondary).width('100%').padding({ left: 20, right: 20, top: 8, bottom: 8 })
            if (this.message || this.stale) {
              Column({ space: 4 }) {
                Text(this.stale ? localizedText($r('app.string.text_the_original_file_has_changed_and_the')) : this.message).fontSize(13).fontColor(UiColor.error).width('100%')
                if (this.stale && this.message) { Text(this.message).fontSize(12).fontColor(UiColor.secondary).width('100%') }
                Row({ space: 12 }) {
                  Button($r('app.string.text_reread')).fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.recreate() })
                  if (this.pendingGroup && !this.stale) { Button($r('app.string.text_retry_application')).fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.message = ''; this.applyPreview() }) }
                  if (this.preview && !this.pendingGroup) { Button($r('app.string.text_retry_preview')).fontSize(12).backgroundColor(Color.Transparent).fontColor(UiColor.primary).onClick((): void => { this.retryPreview() }) }
                }
              }.width('100%').padding({ left: 20, right: 20, bottom: 8 })
            }
            OrgFileConflictView({ renderedHtml: this.html, title: this.file.title() || this.path, revision: `${this.renderRevision}`,
              conflictCards: this.conflictCards(), navigation: this.navigation,
              conflictCardActivated: (id: string, action: string): void => { this.activateCard(id, action) },
              ready: (): void => {
                if (this.restoredPosition !== undefined) {
                  const position = this.restoredPosition
                  this.restoredPosition = undefined
                  this.navigation.restorePosition(position)
                }
              },
              failed: (message: string): void => { this.message = message } }).width('100%').layoutWeight(1)
            if (this.conflicts.length === 0) {
              Text($r('app.string.text_the_conflict_of_this_document_has_been')).fontSize(14).fontColor(UiColor.secondary).padding(12)
              Button($r('app.string.text_done')).height(44).margin({ bottom: 12 }).onClick((): void => { this.exit() })
            } else {
              Row({ space: 8 }) {
                Button('‹').fontSize(22).height(44).width(48).backgroundColor(UiColor.container)
                  .fontColor(UiColor.primary).enabled(!this.saving && !this.stale && !this.pendingGroup && this.conflicts.length > 1)
                  .accessibilityText($r('app.string.text_previous_conflict')).onClick((): void => { this.selectAdjacent(-1) })
                Text(`${this.selectedId ? this.conflicts.findIndex(item => item.id === this.selectedId) + 1 : '—'} / ${this.conflicts.length}`)
                  .fontSize(13).fontColor(UiColor.primary).layoutWeight(1).textAlign(TextAlign.Center)
                Button('›').fontSize(22).height(44).width(48).backgroundColor(UiColor.container)
                  .fontColor(UiColor.primary).enabled(!this.saving && !this.stale && !this.pendingGroup)
                  .accessibilityText($r('app.string.text_next_conflict')).onClick((): void => { this.selectAdjacent(1) })
              }.width('100%').padding({ left: 16, right: 16, top: 8, bottom: 12 })
                .gesture(PanGesture({ direction: PanDirection.Horizontal, distance: 32 }).onActionEnd((event: GestureEvent): void => {
                  this.selectAdjacent(event.offsetX < 0 ? 1 : -1)
                }))
            }
          }
        }.width('100%').height('100%')
      }
    }.width('100%').height('100%')
      .bindSheet($$this.targetsVisible, this.targetTree, {
        height: SheetSize.FIT_CONTENT, preferType: SheetType.BOTTOM, backgroundColor: UiColor.container, showClose: true
      })
  }
}
