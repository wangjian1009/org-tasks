export function queueSync(
  idempotencyKey: string,
  jobId: string,
  reason: string,
  includeCalendar: boolean,
  foreground: boolean,
  now: number
): Promise<number>;
