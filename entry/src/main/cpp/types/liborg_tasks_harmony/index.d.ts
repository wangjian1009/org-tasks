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
  title(): string | null;
  titleParts(): TitlePart[];
  sourceBytes(): Uint8Array;
  renderHtml(): string;
}

export class Task {
  private constructor();
  isDone(): boolean;
  // Core 生成的逻辑路径 MD5，独立于源字节偏移、状态和首尾进度。
  readonly id: string;
  readonly repoId: string;
  readonly heading: string;
  readonly category: string | null;
  readonly headingParts: TitlePart[];
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
  readonly bodyHtml: string;
  readonly logbookHtml: string;
  readonly progress: number;
  readonly hasList: boolean;
  readonly isRepeating: boolean;
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
  fileMetadata(): Promise<OrgFileMetadata[]>;
  readonly id: string;
  readonly rootDirectory: string;
  load(): Promise<void>;
  createTask(path: string, task: NewTask, queueUpload: boolean, insertAtTop?: boolean): Promise<void>;
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
