export function initialize(dataDir: string): Promise<number>;

export function finishSync(succeeded: boolean, now: number): Promise<number>;

export function queueSync(
  idempotencyKey: string,
  jobId: string,
  reason: string,
  includeCalendar: boolean,
  foreground: boolean,
  now: number
): Promise<number>;
