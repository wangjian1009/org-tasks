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
  snapshot(): Promise<RepositorySnapshot>;
  sync(policy: WebDavSyncPolicy, monitor?: WebDavSyncMonitor): Promise<SyncRecord>;
}
