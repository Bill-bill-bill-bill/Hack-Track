/**
 * Client for hacktrack-bridge, the local companion service on Kali (tools/hacktrack-bridge).
 * The page is static, so machine actions (Exam mode AI lockdown, terminals, ...) go through
 * the bridge on 127.0.0.1:8790. POSTs send X-HT-Bridge: 1, which the bridge requires.
 */
export const BRIDGE_URL = 'http://127.0.0.1:8790';

export interface ExamSideStatus {
  last_run?: number | null;
  last_seen?: number | null;
  action?: string | null;
  left: number | null;
  rc?: number | null;
  active?: boolean | null;
  online?: boolean;
  log: string;
}

export interface ExamGuardState {
  now: number;
  start: number | null;
  lead_min: number;
  switch_at: number | null;
  active: boolean;
  activated_at: number | null;
  activated_by: 'schedule' | 'manual' | null;
  busy: boolean;
  restore_pending: boolean;
  kali: ExamSideStatus;
  host: ExamSideStatus;
}

async function call<T>(path: string, body?: unknown, timeoutMs = 4000): Promise<T> {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const res = await fetch(`${BRIDGE_URL}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: body === undefined ? undefined : { 'Content-Type': 'application/json', 'X-HT-Bridge': '1' },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: ctl.signal,
      cache: 'no-store',
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((data as { error?: string }).error || `bridge HTTP ${res.status}`);
    return data as T;
  } finally {
    clearTimeout(t);
  }
}

export const examGuard = {
  state: () => call<ExamGuardState>('/api/exam/state'),
  /** start: epoch ms (or null to clear); leadMin: minutes before start to switch on. */
  schedule: (start: number | null, leadMin: number) =>
    call<ExamGuardState>('/api/exam/schedule', { start, lead_min: leadMin }),
  on: () => call<ExamGuardState>('/api/exam/on', {}),
  off: () => call<ExamGuardState>('/api/exam/off', {}),
};

/** Value for <input type="datetime-local"> from epoch seconds, in local time. */
export function toLocalInput(epochS: number | null): string {
  if (epochS == null) return '';
  const d = new Date(epochS * 1000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** Epoch ms from a datetime-local value (local time), or null if empty/invalid. */
export function fromLocalInput(v: string): number | null {
  if (!v) return null;
  const ms = new Date(v).getTime();
  return Number.isFinite(ms) ? ms : null;
}
