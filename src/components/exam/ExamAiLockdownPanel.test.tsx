import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, fireEvent, waitFor } from '@testing-library/react';
import { ExamAiLockdownPanel } from './ExamAiLockdownPanel';
import { fromLocalInput, toLocalInput } from '../../utils/hackTrackBridge';

const base = {
  now: 1_800_000_000, start: null, lead_min: 30, switch_at: null, active: false,
  activated_at: null, activated_by: null, busy: false, restore_pending: false,
  kali: { last_run: null, left: null, log: '' },
  host: { last_seen: null, left: null, log: '', online: false },
};

function mockFetch(handler: (url: string, init?: RequestInit) => unknown) {
  const fn = vi.fn(async (url: string, init?: RequestInit) => ({
    ok: true, status: 200, json: async () => handler(url, init),
  }));
  vi.stubGlobal('fetch', fn);
  return fn;
}

afterEach(() => vi.unstubAllGlobals());

describe('ExamAiLockdownPanel', () => {
  it('says the bridge is offline when it cannot be reached', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => { throw new TypeError('NetworkError'); }));
    render(<ExamAiLockdownPanel />);
    expect(await screen.findByText('BRIDGE OFFLINE')).toBeInTheDocument();
    expect(screen.getByTestId('exam-ai-on-btn')).toBeDisabled();
  });

  it('saves the start time as epoch ms with the lead, sending the bridge header', async () => {
    const f = mockFetch(() => base);
    render(<ExamAiLockdownPanel />);
    await screen.findByText('OFF');
    fireEvent.change(screen.getByTestId('exam-ai-start'), { target: { value: '2027-01-15T09:00' } });
    fireEvent.change(screen.getByTestId('exam-ai-lead'), { target: { value: '45' } });
    fireEvent.click(screen.getByTestId('exam-ai-save'));
    await waitFor(() => expect(f.mock.calls.some(([u]) => String(u).endsWith('/api/exam/schedule'))).toBe(true));
    const [, init] = f.mock.calls.find(([u]) => String(u).endsWith('/api/exam/schedule'))!;
    expect(JSON.parse(String(init!.body))).toEqual({ start: new Date('2027-01-15T09:00').getTime(), lead_min: 45 });
    expect((init!.headers as Record<string, string>)['X-HT-Bridge']).toBe('1');
  });

  it('shows ON with per-machine status and offers the restore button', async () => {
    mockFetch(() => ({
      ...base, active: true, activated_at: 1_799_999_000, activated_by: 'schedule',
      kali: { last_run: 1_799_999_900, left: 0, log: 'CHECK: AI processes left: 0' },
      host: { last_seen: 1_799_999_950, left: 2, log: '', online: true, active: true },
    }));
    render(<ExamAiLockdownPanel />);
    expect(await screen.findByText('ON')).toBeInTheDocument();
    expect(screen.getByTestId('exam-ai-kali-status')).toHaveTextContent('AI off');
    expect(screen.getByTestId('exam-ai-host-status')).toHaveTextContent('2 AI process(es) still running');
    expect(screen.getByTestId('exam-ai-off-btn')).toBeInTheDocument();
    expect(screen.queryByTestId('exam-ai-start')).not.toBeInTheDocument();
  });

  it('round-trips datetime-local values', () => {
    const ms = fromLocalInput('2027-01-15T09:00')!;
    expect(toLocalInput(ms / 1000)).toBe('2027-01-15T09:00');
    expect(fromLocalInput('')).toBeNull();
  });
});
