export function initialize(dataDir: string): Promise<number>;

export function recordSync(
  repoId: string,
  recordId: string,
  startedAt: number,
  finishedAt: number,
  succeeded: boolean
): Promise<number>;

export function executeCore(request: string): Promise<string>;
