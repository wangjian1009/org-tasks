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
export type TaskModificationField = 'TITLE' | 'BODY' | 'TODO' | 'PRIORITY' | 'TAGS' | 'SCHEDULE' | 'DEADLINE' | 'CLOSED' | 'CREATED' | 'ADDRESS_LINK';
export interface TaskModification { field: TaskModificationField; value: string | string[] | TaskAddressChange | null; }
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
  readonly todoKind: 'pending' | 'done' | null;
  readonly priority: string;
  readonly scheduled: string;
  readonly deadline: string;
  readonly tags: string[];
  readonly filePath: string;
  readonly fileName: string;
  readonly level: number;
  readonly body: string;
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
  compareMerge(repo: Repo, syncId: string): Promise<MergeComparison>;
  applyMerge(repo: Repo, comparison: MergeComparison): Promise<MergeOutcome>;
}

export class Workspace {
  constructor();
  setTodoDefaults(settings: string): Promise<void>;
  repos(): Promise<Repo[]>;
  addRepo(rootDirectory: string): Promise<Repo>;
  removeRepo(rootDirectory: string): Promise<void>;
  search(expression: string): Promise<Task[]>;
  query(query: TaskQuery): Promise<TaskQueryResult>;
  refileTargets(query?: RefileTargetQuery): Promise<RefileTarget[]>;
  executeTaskOperations(group: TaskOperationGroup): Promise<TaskOperationResult>;
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
  history(): Promise<SyncRecord[]>;
  historyDetail(syncId: string): Promise<SyncRecordDetail>;
  conflicts(): Promise<ConflictSync[]>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor, options?: SyncOptions): Promise<SyncRecord>;
}

export interface OrgFileMetadata {
  readonly repoId: string;
  readonly path: string;
  readonly title: string | null;
  readonly titleParts: TitlePart[];
  readonly isIgnore: boolean;
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
export type MergeMode = 'acceptRemote' | 'mergeTasks';
export type MergeResolution = 'local' | 'remote' | 'remove';
export type MergeChangeState = 'unchanged' | 'added' | 'modified' | 'deleted' | 'unmatched';
export interface MergeChange {
  id: string;
  path: string;
  kind: 'added' | 'modified' | 'deleted';
  preamble: boolean;
  localChange: MergeChangeState;
  remoteChange: MergeChangeState;
  local: MergeVersion | null;
  remote: MergeVersion | null;
  resolution: MergeResolution | null;
}
export interface MergeFileVersion {
  path: string;
  localHash: string;
  remoteHash: string;
  remoteEtag: string | null;
  remoteMissing: boolean;
  localMissing: boolean;
}
export interface MergeComparison {
  syncId: string;
  repoId: string;
  repositoryVersion: string;
  endpointVersion: string;
  mode: MergeMode;
  files: MergeFileVersion[];
  unchangedCount: number;
  changes: MergeChange[];
}
export interface ConflictSync { syncId: string; paths: string[]; }
export interface MergeBackup { path: string; backupPath: string; }
export interface MergeOutcome { syncId: string; result: 'succeeded' | 'failed'; backups: MergeBackup[]; }


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
