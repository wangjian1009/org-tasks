export function initialize(dataDir: string): Promise<number>;

export function recordSync(
  repoId: string,
  recordId: string,
  startedAt: number,
  finishedAt: number,
  succeeded: boolean
): Promise<number>;

export function openWorkspace(rootDirectory: string): Promise<Workspace>;

export class Workspace {
  repos(): Promise<Repo[]>;
  snapshot(): Promise<string>;
  search(expression: string): Promise<string>;
  syncWebDav(webdavUrl: string, username: string, password: string): Promise<string>;
}

export class Repo {
  id(): string;
  snapshot(): Promise<string>;
}
