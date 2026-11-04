export interface NewTask {
  heading: string;
  scheduled: string;
  deadline: string;
  tags: string[];
  priority: string;
}

export interface CoreError extends Error {
  readonly code: 'invalidInput' | 'invalidState' | 'store' | 'bridge';
}

export class OrgFile {
  private constructor();
  readonly repoId: string;
  readonly path: string;
  readonly todo: TodoMetadata;
  category(): string | null;
  sourceBytes(): Uint8Array;
}

export class Task {
  private constructor();
  isDone(): boolean;
  readonly id: string;
  readonly repoId: string;
  readonly heading: string;
  readonly todoState: string;
  readonly todoKind: 'pending' | 'done' | null;
  readonly priority: string;
  readonly scheduled: string;
  readonly deadline: string;
  readonly tags: string[];
  readonly filePath: string;
  readonly fileName: string;
  readonly level: number;
  readonly body: string;
  readonly progress: number;
}

export interface SyncRecord {
  id: string;
  result: 'succeeded' | 'failed' | 'cancelled' | 'interrupted';
  started_at: number;
  finished_at: number | null;
  files: number;
  conflicts: string[];
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

export interface TaskQuery {
  expression?: string;
  categories?: (string | null)[];
  excludedFiles?: string[];
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
}

export class Repo {
  private constructor();
  file(path: string): Promise<OrgFile>;
  files(): Promise<OrgFile[]>;
  readonly id: string;
  readonly rootDirectory: string;
  load(): Promise<void>;
  createTask(path: string, task: NewTask, queueUpload: boolean): Promise<void>;
  conflicts(): Promise<ConflictSync[]>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor, options?: SyncOptions): Promise<SyncRecord>;
}


export interface MergeVersion {
  title: string;
  source: string;
  parent: string | null;
  level: number;
}
export type MergeMode = 'acceptRemote' | 'mergeTasks';
export type MergeResolution = 'local' | 'remote' | 'remove';
export interface MergeChange {
  id: string;
  path: string;
  kind: 'added' | 'modified' | 'deleted';
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
