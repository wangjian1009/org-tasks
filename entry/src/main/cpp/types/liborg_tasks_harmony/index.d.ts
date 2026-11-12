export interface TitleCount {
  readonly completed: number | null;
  readonly total: number | null;
}

export interface TitlePart {
  readonly text: string;
  readonly href: string | null;
  readonly isLink: boolean;
  readonly count: TitleCount | null;
}

export interface AddressLink {
  readonly uri: string;
  readonly label: string;
}

export interface CoreError extends Error {
  readonly code: 'invalidInput' | 'invalidState' | 'store' | 'bridge' | 'previewUnavailable' | 'previewExpired' | 'previewVersionMismatch' | 'sourceVersionMismatch' | 'conflictTargetRequired' | 'invalidConflictTarget' | 'conflictDecisionRequired' | 'mixedPreviewOperation';
}

export interface TaskPath { repoId: string; file: string | null; titles: string[]; occurrence?: number; }
export interface TaskPosition { parent: TaskPath; after?: TaskPath | null; }
export interface TaskCreation {
  position: TaskPosition; title: string; body?: string; state?: string | null; priority?: string | null;
  tags?: string[]; scheduled?: string | null; deadline?: string | null;
}
export interface TaskAddressChange { oldUri: string; newUri: string; }
export type TaskModificationField = 'TITLE' | 'BODY' | 'NOTES' | 'CHECKLIST' | 'TODO' | 'PRIORITY' | 'TAGS' | 'SCHEDULE' | 'SCHEDULE_DATE' | 'SCHEDULE_REPEAT' | 'DEADLINE' | 'DEADLINE_DATE' | 'DEADLINE_REPEAT' | 'ADDRESS_LINK';
export type TaskRepeatMode = 'cumulative' | 'catchUp' | 'afterCompletion';
export type TaskRepeatUnit = 'hour' | 'day' | 'week' | 'month' | 'year';
export interface TaskRepeatRule { mode: TaskRepeatMode; interval: number; unit: TaskRepeatUnit; }
export interface TaskRepeatInfo { readonly date: string; readonly hasTime: boolean; readonly rule: TaskRepeatRule | null; }
export interface TaskChecklistItem { readonly id: string; readonly siblingGroup: string; readonly text: string; readonly checked: boolean; readonly partial: boolean; readonly depth: number; }
export interface TaskEditContent { readonly ownTags: string[]; readonly notes: string; readonly checklist: TaskChecklistItem[]; readonly scheduledRepeat: TaskRepeatInfo | null; readonly deadlineRepeat: TaskRepeatInfo | null; }
export interface SupportTags { readonly tags: string[]; readonly groups: string[][]; }
export type TaskChecklistChange = { type: 'add'; text: string } | { type: 'edit'; id: string; text: string } | { type: 'setChecked'; id: string; checked: boolean } | { type: 'remove'; id: string } | { type: 'move'; id: string; beforeId: string | null };
export interface TaskModification { field: TaskModificationField; value: string | string[] | TaskAddressChange | TaskChecklistChange | TaskRepeatRule | null; }
export interface TaskModificationOperation { path: TaskPath; modifications: TaskModification[]; }
export interface TaskMovement { path: TaskPath; position: TaskPosition; }
export interface TaskDeletion { path: TaskPath; }
export interface TaskMergeRequest { paths: TaskPath[]; fileVersion: string; }
export interface TaskMergePlan { operationGroup: TaskOperationGroup; mainPath: TaskPath; }
export interface TaskConfilictSelection { path?: TaskPath; id: string; action: 'discard' | 'useLocal'; target?: ConflictTarget | null; }
export type TaskOperationType = 'Creation' | 'Modification' | 'Movement' | 'Deletion' | 'ConfilictSelection';
export interface TaskOperation { type: TaskOperationType; data: TaskCreation | TaskModificationOperation | TaskMovement | TaskDeletion | TaskConfilictSelection; }
export interface TaskFileVersion { repoId: string; file: string; version: string; }
export interface TaskOperationGroup { operations: TaskOperation[]; queueRepoIds?: string[]; fileVersions?: TaskFileVersion[]; }
export type DataChangeEvent = { type: 'repositoryChanged'; repoId: string };
export type DataChangeMonitor = (event: DataChangeEvent) => void;
export interface RefileTargetQuery { files?: OrgFileRef[]; excludedFiles?: OrgFileRef[]; }
export interface RefileTarget {
  repoId: string; path: string; fullPath: TaskPath; headingPath: string[]; position: SourcePosition;
  category: string | null; fileVersion: string;
}
export class OrgFile {
  private constructor();
  readonly repoId: string;
  readonly path: string;
  readonly fullPath: TaskPath;
  readonly todo: TodoMetadata;
  readonly fileVersion: string;
  category(): string | null;
  title(): string | null;
  titleParts(): TitlePart[];
  sourceBytes(): Uint8Array;
  renderHtml(): string;
  conflicts(): FileConflict[];
  nodes(): Task[];
  node(path: TaskPath): Task;
  editableNodePaths(): TaskPath[];
  insertionPositions(): TaskPosition[];
  readonly hasConflict: boolean;
  readonly conflictIds: string[];
}

export class Task {
  private constructor();
  isDone(): boolean;
  project(): string | null;
  readonly projectName: string | null;
  // Core 生成的明文逻辑路径，独立于源字节偏移、状态和首尾进度。
  readonly id: string;
  readonly fullPath: TaskPath;
  readonly taskId: string | null;
  readonly fileVersion: string;
  readonly repoId: string;
  readonly heading: string;
  readonly category: string | null;
  readonly headingParts: TitlePart[];
  readonly state: TaskState | null;
  taskStateOf(category: TaskStateCategory): TaskState | null;
  readonly createdAt: number | null;
  readonly closedAt: number | null;
  readonly modifiedAt: number | null;
  readonly priority: TaskPriority | null;
  readonly priorityOptions: TaskPriority[];
  taskPriorityOf(category: PeriodCategory): TaskPriority | null;
  readonly scheduled: string;
  readonly deadline: string;
  readonly tags: string[];
  readonly ownTags: string[];
  readonly inheritedTags: string[];
  readonly supportTags: SupportTags | null;
  readonly editContent: TaskEditContent;
  readonly filePath: string;
  readonly fileName: string;
  readonly level: number;
  readonly body: string;
  readonly bodyFirstLine: string | null;
  readonly addressLinks: AddressLink[];
  readonly bodyHtml: string;
  readonly logbookHtml: string;
  readonly progress: number;
  readonly hasList: boolean;
  readonly hasText: boolean;
  readonly isRepeating: boolean;
  readonly isHabit: boolean;
}

export interface SyncRecord {
  id: string;
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted';
  started_at: number;
  finished_at: number | null;
  files: number;
  downloadedFiles: number;
  uploadedFiles: number;
  conflicts: string[];
  executionResult: 'succeeded' | 'failed' | 'cancelled' | 'interrupted';
  transfer: 'unchanged' | 'download' | 'upload' | 'bidirectional';
  errorCategory: 'Network' | 'Authentication' | 'Tls' | 'Validation' | 'LocalStorage' | 'Conflict' | null;
  errorMessage: string | null;
}

export interface SyncFileRecord {
  path: string;
  outcome: 'unchanged' | 'downloaded' | 'uploaded' | 'created' | 'deleted' | 'updated' | 'merged' | 'conflict' | 'failed' | 'skipped';
  section: 'upload' | 'download' | 'merge' | 'unchanged' | 'conflict' | null;
  backup: OrgFileMetadata | null;
}

export interface SyncHistoryError { path: string | null; message: string; }

export interface SyncRecordDetail {
  summary: SyncRecord;
  files: SyncFileRecord[];
  errors: SyncHistoryError[];
}

export type WebDavSyncEvent =
  | { type: 'started'; repoId: string }
  | { type: 'listingStarted' }
  | { type: 'listed'; files: number }
  | { type: 'fileStarted'; path: string; index: number; total: number }
  | { type: 'fileProcessed'; path: string; action: string; state: string }
  | { type: 'httpRequest'; method: string; path: string }
  | { type: 'httpResponse'; method: string; path: string; status: number | null }
  | { type: 'finished'; result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted'; files: number };

export type WebDavSyncMonitor = (event: WebDavSyncEvent) => void;

export interface SyncOptions { excludedDirectories: string[]; }

export interface OrgFileRef { repoId: string; path: string; }

export interface TaskQuery {
  expression?: string;
  categories?: (string | null)[];
  excludedFiles?: OrgFileRef[];
  includeDone?: boolean;
  includeComposeTasks?: boolean;
}

export interface TaskCategory {
  key: string;
  category: string | null;
  count: number;
}

export interface TaskQueryResult {
  tasks: Task[];
  categories: TaskCategory[];
}

export interface FileQuery {
  includeFiles?: OrgFileRef[];
  excludeFiles?: OrgFileRef[];
  fileTags?: string[];
  isProject?: boolean | null;
  includeIgnored?: boolean;
}
export interface NotificationQuery {}
export interface TaskCoreQuery { type: 'task'; query: TaskQuery; repoIds?: string[]; }
export interface FileCoreQuery { type: 'file'; query: FileQuery; }
export interface NotificationCoreQuery { type: 'notification'; query: NotificationQuery; }
export type CoreQuery = TaskCoreQuery | FileCoreQuery | NotificationCoreQuery;
export interface TaskCoreQueryResult { type: 'task'; result: TaskQueryResult; }
export interface FileCoreQueryResult { type: 'file'; result: OrgFileMetadata[]; }
export interface NotificationCoreQueryResult { type: 'notification'; result: CoreNotification[]; }
export type CoreQueryResult = TaskCoreQueryResult | FileCoreQueryResult | NotificationCoreQueryResult;

export class WebDavSyncPolicy {
  constructor(webdavUrl: string, username: string, password: string);
  testConnection(): Promise<void>;
}

export interface SyncConflictNotification {
  type: 'syncConflict';
  rootDirectory: string;
  repoId: string;
  path: string;
}

export interface SyncRequiredNotification { type: 'syncRequired'; }
export type CoreNotification = SyncConflictNotification | SyncRequiredNotification;

export type NotificationUpdate =
  | { type: 'repositoryChanged'; repoId: string }
  | { type: 'globalNotificationsChanged' };
export type NotificationUpdateMonitor = (event: NotificationUpdate) => void;

export class Workspace {
  constructor();
  getSettings(): Promise<CoreSettings>;
  setSettings(settings: CoreSettings): Promise<void>;
  setTodoDefaults(settings: string): Promise<void>;
  setPreviewRoot(root: string): Promise<void>;
  createConflictPreview(request: ConflictPreviewRequest): Promise<ConflictPreview>;
  fileAt(path: TaskPath): Promise<OrgFile>;
  repos(): Promise<Repo[]>;
  addRepo(rootDirectory: string): Promise<Repo>;
  removeRepo(rootDirectory: string): Promise<void>;
  query(queries: CoreQuery[]): Promise<CoreQueryResult[]>;
  refileTargets(query?: RefileTargetQuery): Promise<RefileTarget[]>;
  executeTaskOperations(group: TaskOperationGroup): Promise<void>;
  taskMergeOperations(request: TaskMergeRequest): Promise<TaskMergePlan>;
  watchNotifications(monitor: NotificationUpdateMonitor): Promise<void>;
  stopWatchingNotifications(): void;
  watchDataChanges(monitor: DataChangeMonitor): Promise<number>;
  stopWatchingDataChanges(subscriptionId: number): void;
  reload(): Promise<void>;
}

export class Repo {
  private constructor();
  file(path: string): Promise<OrgFile>;
  loadFiles(ignoreFiles?: string[]): Promise<OrgFile[]>;
  readonly id: string;
  readonly rootDirectory: string;
  readonly fullPath: TaskPath;
  load(): Promise<void>;
  reset(): Promise<void>;
  history(): Promise<SyncRecord[]>;
  historyDetail(syncId: string): Promise<SyncRecordDetail>;
  lastEffectSync(): Promise<SyncRecord | null>;
  historyFile(target: HistoryFileTarget): Promise<OrgFile>;
  conflicts(): Promise<ConflictSync[]>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor, options?: SyncOptions): Promise<SyncRecord>;
}

export interface OrgFileMetadata {
  readonly priorityOptions: TaskPriority[];
  taskPriorityOf(category: PeriodCategory): TaskPriority | null;
  taskStateOf(category: TaskStateCategory): TaskState | null;
  project(): string | null;
  readonly projectName: string | null;
  readonly repoId: string;
  readonly path: string;
  readonly title: string | null;
  readonly titleParts: TitlePart[];
  readonly tagOptions: string[];
  readonly tagGroups: string[][];
  readonly isIgnore: boolean;
  readonly hasConflict: boolean;
  readonly taskCount: number;
  readonly byteLength: number;
  readonly modifiedAt: number | null;
}


export interface ConflictSync { syncId: string; paths: string[]; }


export interface SourcePosition { line: number; column: number; byte_offset: number; }
export interface SourceRange { start: SourcePosition; end: SourcePosition; }
export type PeriodCategory = 'Hight' | 'Middle' | 'Low';
export interface TaskPriority { name: string; category: PeriodCategory | null; }

export type TaskStateCategory = 'Todo' | 'Doing' | 'Wait' | 'Done' | 'Cancel';
export interface TaskState { name: string; category: TaskStateCategory | null; }
export interface CoreSettings { additionStates: TaskState[]; }

export interface TodoDeclaration { keyword: string; value: string; range: SourceRange; }
export interface TodoStateMetadata {
  name: string;
  kind: 'pending' | 'done';
  category: TaskStateCategory | null;
  fastKey: string | null;
  enterLog: 'time' | 'note' | null;
  leaveLog: 'time' | 'note' | null;
}
export interface TodoWorkflow { kind: 'sequence' | 'type'; states: TodoStateMetadata[]; }
export interface TodoMetadata {
  source: 'globalDefault' | 'inBuffer';
  declarations: TodoDeclaration[];
  workflows: TodoWorkflow[];
  pendingKeywords: string[];
  initialState: string | null;
}

export function defaultTodoSettings(): Promise<string>;
export function defaultSyncOptions(): Promise<SyncOptions>;
export function normalizeSyncOptions(options: SyncOptions): Promise<SyncOptions>;

export interface HistoryFileTarget { syncId: string; path: string; resolved: boolean; }

export type ConflictTarget = { type: 'existing'; data: TaskPath } | { type: 'insert'; data: TaskPosition } | { type: 'replaceMain' };
export interface ConflictPreviewRequest { file: TaskPath; conflictId: string; sourceVersion: string; }
export interface FileConflict {
  id: string; title: string; reason: string; sourceRange: SourceRange;
  availableActions: ('discard' | 'useLocal')[]; suggestedTarget: ConflictTarget | null; requiresTarget: boolean;
  displayAnchor: SourceRange | null; displayAtTarget: boolean; candidateContent: string; candidateHtml: string;
}
export interface ConflictPreviewDiffLine { kind: 'context' | 'added' | 'removed'; beforeLine: number | null; afterLine: number | null; text: string; }
export interface ConflictPreviewChange {
  kind: 'insert' | 'delete' | 'replace' | 'move'; area: 'main' | 'conflictMaterial';
  before: SourceRange | null; after: SourceRange | null; beforePath: TaskPath | null; afterPath: TaskPath | null;
  lines: ConflictPreviewDiffLine[];
}
export interface ConflictPreviewChanges { sourceVersion: string; previewVersion: string; changes: ConflictPreviewChange[]; }
export interface ConflictPreviewFinishOptions { previewVersion: string; }
export interface ConflictPreviewProjectionRequest { conflictId: string; previewVersion: string; target?: ConflictTarget; }
export interface ConflictPreviewProjection {
  conflictId: string; workingVersion: string; status: 'ready' | 'targetRequired' | 'unavailable';
  beforeText: string; afterText: string; content: string; renderedHtml: string; changes: ConflictPreviewChanges;
}
export class ConflictPreview {
  private constructor();
  readonly id: string;
  readonly fullPath: TaskPath;
  readonly sourcePath: TaskPath;
  readonly sourceVersion: string;
  readonly conflictId: string;
  file(): Promise<OrgFile>;
  sourceFile(): Promise<OrgFile>;
  conflicts(): Promise<FileConflict[]>;
  changes(): Promise<ConflictPreviewChanges>;
  project(request: ConflictPreviewProjectionRequest): Promise<ConflictPreviewProjection>;
  finish(options: ConflictPreviewFinishOptions): Promise<TaskOperationGroup>;
  discard(): Promise<void>;
}
