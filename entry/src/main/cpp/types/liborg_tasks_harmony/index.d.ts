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
  readonly code: 'invalidInput' | 'invalidState' | 'store' | 'bridge';
}

export interface TaskPath { repoId: string; file: string | null; titles: string[]; occurrence?: number; }
export interface TaskPosition { parent: TaskPath; after?: TaskPath | null; }
export interface TaskCreation {
  position: TaskPosition; title: string; body?: string; state?: string | null; priority?: string | null;
  tags?: string[]; scheduled?: string | null; deadline?: string | null; closed?: string | null; recordCreated?: boolean;
}
export interface TaskAddressChange { oldUri: string; newUri: string; }
export type TaskModificationField = 'TITLE' | 'BODY' | 'NOTES' | 'CHECKLIST' | 'TODO' | 'PRIORITY' | 'TAGS' | 'SCHEDULE' | 'SCHEDULE_DATE' | 'DEADLINE' | 'DEADLINE_DATE' | 'CLOSED' | 'CREATED' | 'ADDRESS_LINK';
export interface TaskChecklistItem { readonly id: string; readonly text: string; readonly checked: boolean; readonly partial: boolean; readonly depth: number; }
export interface TaskEditContent { readonly ownTags: string[]; readonly notes: string; readonly checklist: TaskChecklistItem[]; }
export type TaskChecklistChange = { type: 'add'; text: string } | { type: 'edit'; id: string; text: string } | { type: 'setChecked'; id: string; checked: boolean } | { type: 'remove'; id: string };
export interface TaskModification { field: TaskModificationField; value: string | string[] | TaskAddressChange | TaskChecklistChange | null; }
export interface TaskModificationOperation { path: TaskPath; modifications: TaskModification[]; }
export interface TaskMovement { path: TaskPath; position: TaskPosition; }
export interface TaskDeletion { path: TaskPath; }
export type TaskOperationType = 'Creation' | 'Modification' | 'Movement' | 'Deletion';
export interface TaskOperation { type: TaskOperationType; data: TaskCreation | TaskModificationOperation | TaskMovement | TaskDeletion; }
export interface TaskFileVersion { repoId: string; file: string; version: string; }
export interface TaskOperationGroup { operations: TaskOperation[]; queueRepoIds?: string[]; fileVersions?: TaskFileVersion[]; }
export interface TaskFileFallback { repoId: string; file: string; before: string | null; after: string; }
export interface TaskFallbackGroup { files: TaskFileFallback[]; }
export interface TaskOperationResult { paths: (TaskPath | null)[]; fallback: TaskFallbackGroup; tasks: Task[]; }

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
  readonly hasConflict: boolean;
}

export class Task {
  private constructor();
  isDone(): boolean;
  // Core 生成的明文逻辑路径，独立于源字节偏移、状态和首尾进度。
  readonly id: string;
  readonly fullPath: TaskPath;
  readonly taskId: string | null;
  readonly fileVersion: string;
  readonly repoId: string;
  readonly heading: string;
  readonly category: string | null;
  readonly headingParts: TitlePart[];
  readonly todoState: string;
  readonly isCancelled: boolean;
  readonly createdAt: number | null;
  readonly modifiedAt: number | null;
  readonly todoKind: 'pending' | 'done' | null;
  readonly priority: string;
  readonly scheduled: string;
  readonly deadline: string;
  readonly tags: string[];
  readonly ownTags: string[];
  readonly inheritedTags: string[];
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
  pendingConflicts: number;
  resolvedConflicts: number;
  errorCategory: 'Network' | 'Authentication' | 'Tls' | 'Validation' | 'LocalStorage' | 'Conflict' | null;
  errorMessage: string | null;
}

export interface SyncFileRecord {
  path: string;
  outcome: 'unchanged' | 'downloaded' | 'uploaded' | 'created' | 'deleted' | 'conflict' | 'resolved' | 'failed' | 'skipped';
  section: 'upload' | 'download' | 'conflict' | null;
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

export class WebDavSyncPolicy {
  constructor(webdavUrl: string, username: string, password: string);
  testConnection(): Promise<void>;
}

export interface SyncConflictNotification {
  type: 'syncConflict';
  rootDirectory: string;
  repoId: string;
  syncId: string;
  paths: string[];
}

export interface SyncRequiredNotification { type: 'syncRequired'; }
export type CoreNotification = SyncConflictNotification | SyncRequiredNotification;

export type NotificationUpdate =
  | { type: 'repositoryChanged'; repoId: string }
  | { type: 'globalNotificationsChanged' };
export type NotificationUpdateMonitor = (event: NotificationUpdate) => void;

export class Workspace {
  constructor();
  setTodoDefaults(settings: string): Promise<void>;
  repos(): Promise<Repo[]>;
  addRepo(rootDirectory: string): Promise<Repo>;
  removeRepo(rootDirectory: string): Promise<void>;
  query(query: TaskQuery): Promise<TaskQueryResult>;
  refileTargets(query?: RefileTargetQuery): Promise<RefileTarget[]>;
  executeTaskOperations(group: TaskOperationGroup): Promise<TaskOperationResult>;
  notifications(): Promise<CoreNotification[]>;
  watchNotifications(monitor: NotificationUpdateMonitor): Promise<void>;
  stopWatchingNotifications(): void;
  reload(): Promise<void>;
}

export class Repo {
  private constructor();
  file(path: string): Promise<OrgFile>;
  files(): Promise<OrgFile[]>;
  fileMetadata(): Promise<OrgFileMetadata[]>;
  readonly id: string;
  readonly rootDirectory: string;
  readonly fullPath: TaskPath;
  load(): Promise<void>;
  reset(): Promise<void>;
  history(): Promise<SyncRecord[]>;
  historyDetail(syncId: string): Promise<SyncRecordDetail>;
  lastEffectSync(): Promise<SyncRecord | null>;
  historyFile(target: HistoryFileTarget): Promise<OrgFile>;
  compareConflict(target: ConflictFileTarget): Promise<SyncConflictComparison>;
  resolveConflict(request: SyncConflictResolution): Promise<void>;
  conflicts(): Promise<ConflictSync[]>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor, options?: SyncOptions): Promise<SyncRecord>;
}

export interface OrgFileMetadata {
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


export interface MergeVersion {
  title: string;
  source: string;
  parent: string | null;
  level: number;
}
export type MergeResolution = 'local' | 'remote' | 'remove';
export type MergeChangeState = 'unchanged' | 'added' | 'modified' | 'deleted' | 'unmatched';
export interface SyncConflictChange {
  key: string;
  kind: 'added' | 'modified' | 'deleted';
  preamble: boolean;
  local: MergeVersion | null;
  remote: MergeVersion | null;
}
export interface ConflictSync { syncId: string; paths: string[]; }


export interface SourcePosition { line: number; column: number; byte_offset: number; }
export interface SourceRange { start: SourcePosition; end: SourcePosition; }
export interface TodoDeclaration { keyword: string; value: string; range: SourceRange; }
export interface TodoStateMetadata {
  name: string;
  kind: 'pending' | 'done';
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
  doneKeywords: string[];
  initialState: string | null;
}

export function defaultTodoSettings(): Promise<string>;
export function defaultSyncOptions(): Promise<SyncOptions>;
export function normalizeSyncOptions(options: SyncOptions): Promise<SyncOptions>;

export interface ConflictFileTarget { syncId: string; path: string; }
export interface HistoryFileTarget { syncId: string; path: string; resolved: boolean; }
export interface SyncConflictComparison {
  repoId: string;
  target: ConflictFileTarget;
  localHash: string;
  remoteHash: string;
  localMissing: boolean;
  unchangedCount: number;
  changes: SyncConflictChange[];
}

export interface SyncConflictChoice { key: string; side: MergeResolution; }
export interface SyncConflictResolution {
  target: ConflictFileTarget;
  expectedLocalHash: string;
  expectedRemoteHash: string;
  expectedLocalMissing: boolean;
  choices: SyncConflictChoice[];
}
