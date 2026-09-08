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

export class WebDavSyncPolicy {
  constructor(webdavUrl: string, username: string, password: string);
}

export class Workspace {
  constructor();
  repos(): Promise<Repo[]>;
  addRepo(rootDirectory: string): Promise<void>;
  load(): Promise<void>;
  search(expression: string): Promise<Task[]>;
}

export class Repo {
  id(): string;
  snapshot(): Promise<RepositorySnapshot>;
  sync(policy: WebDavSyncPolicy): Promise<SyncRecord>;
}
