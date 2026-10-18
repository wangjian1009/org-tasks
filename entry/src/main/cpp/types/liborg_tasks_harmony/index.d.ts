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

export interface RepositoryFile {
  path: string;
  source: string;
  byte_length: number;
}

export interface RepositorySnapshot {
  id: string;
  files: RepositoryFile[];
}

export interface Task {
  id: string;
  repoId: string;
  heading: string;
  todoState: string;
  priority: string;
  scheduled: string;
  deadline: string;
  tags: string[];
  filePath: string;
  fileName: string;
  level: number;
  body: string;
  progress: number;
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

export class WebDavSyncPolicy {
  constructor(webdavUrl: string, username: string, password: string);
  testConnection(): Promise<void>;
}

export class Workspace {
  constructor();
  repos(): Promise<Repo[]>;
  addRepo(rootDirectory: string): Promise<Repo>;
  removeRepo(rootDirectory: string): Promise<void>;
  search(expression: string): Promise<Task[]>;
}

export class Repo {
  id(): string;
  rootDirectory(): string;
  load(): Promise<void>;
  createTask(path: string, task: NewTask, queueUpload: boolean): Promise<void>;
  conflicts(): Promise<ConflictSync[]>;
  compareMerge(policy: WebDavSyncPolicy, syncId: string): Promise<MergeComparison>;
  apply(policy: WebDavSyncPolicy, comparison: MergeComparison): Promise<MergeOutcome>;
  snapshot(): Promise<RepositorySnapshot>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor): Promise<SyncRecord>;
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
