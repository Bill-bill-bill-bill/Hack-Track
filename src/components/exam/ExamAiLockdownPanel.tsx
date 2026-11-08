/**
 * Exam mode AI lockdown panel. You set the real exam start time and a lead (default 30 min).
 * hacktrack-bridge switches Exam mode on at start minus lead (or right away with "Exam mode on").
 * While it is on, the bridge kills the AI apps on Kali and the Windows host watcher kills them on
 * the host. "AI back on" restores both. The bridge holds the schedule, so it still fires when
 * this page is closed.
 */
import React, { useCallback, useEffect, useState } from 'react';
import { ShieldOff, ShieldCheck, Power, CalendarClock, ChevronDown, ChevronRight } from 'lucide-react';
import { CyberButton } from '../common/CyberButton';
import { confirmAction } from '../../store/useConfirmStore';
import {
  examGuard,
  fromLocalInput,
  toLocalInput,
  type ExamGuardState,
  type ExamSideStatus,
} from '../../utils/hackTrackBridge';

const fmtTime = (s: number | null | undefined) =>
  s ? new Date(s * 1000).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' }) : '-';

const fmtIn = (secs: number) => {
  const m = Math.max(0, Math.round(secs / 60));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
};

function SideLine({ label, s, active, kind }: { label: string; s: ExamSideStatus; active: boolean; kind: 'kali' | 'host' }) {
  const [open, setOpen] = useState(false);
  const when = kind === 'kali' ? s.last_run : s.last_seen;
  let text: string;
  let tone = 'text-muted';
  if (kind === 'host' && !s.online) {
    text = when ? `watcher last seen ${fmtTime(when)}` : 'watcher not installed or not reporting';
    tone = 'text-callout-warn-fg';
  } else if (active) {
    if (s.left == null) text = when ? `sweep at ${fmtTime(when)}` : 'waiting for the first sweep';
    else if (s.left === 0) { text = `AI off · checked ${fmtTime(when)}`; tone = 'text-callout-success-fg'; }
    else { text = `${s.left} AI process(es) still running · ${fmtTime(when)}`; tone = 'text-callout-danger-fg'; }
  } else {
    text = kind === 'host' ? (s.active ? 'AI still off: restoring' : 'AI apps normal') : 'AI apps normal';
  }
  return (
    <div className="text-xs">
      <button
        type="button"
        className="flex items-center gap-1.5 w-full text-left"
        onClick={() => setOpen((o) => !o)}
        data-testid={`exam-ai-${kind}-status`}
      >
        {open ? <ChevronDown className="w-3 h-3" /> : <ChevronRight className="w-3 h-3" />}
        <span className="font-semibold text-primary w-24 flex-shrink-0">{label}</span>
        <span className={tone}>{text}</span>
      </button>
      {open && s.log && (
        <pre className="mt-1 max-h-48 overflow-auto rounded bg-surface-sunken border border-subtle p-2 text-[11px] whitespace-pre-wrap">
          {s.log}
        </pre>
      )}
    </div>
  );
}

export const ExamAiLockdownPanel: React.FC = () => {
  const [st, setSt] = useState<ExamGuardState | null>(null);
  const [err, setErr] = useState<string | null>(null);
  const [startInput, setStartInput] = useState('');
  const [lead, setLead] = useState(30);
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);

  const refresh = useCallback(async () => {
    try {
      const s = await examGuard.state();
      setSt(s);
      setErr(null);
      if (!dirty) {
        setStartInput(toLocalInput(s.start));
        setLead(s.lead_min);
      }
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    }
  }, [dirty]);

  useEffect(() => {
    void refresh();
    const t = setInterval(() => void refresh(), 5000);
    return () => clearInterval(t);
  }, [refresh]);

  const act = async (fn: () => Promise<ExamGuardState>) => {
    setBusy(true);
    try {
      setSt(await fn());
      setErr(null);
      setDirty(false);
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const saveSchedule = () => act(() => examGuard.schedule(fromLocalInput(startInput), lead));
  const turnOn = async () => {
    if (await confirmAction({
      title: 'Turn Exam mode on now?',
      body: 'This kills Claude, Codex, LM Studio, Ollama, Notion, Copilot, Daybreak and grokbot on Kali and on the Windows host, and keeps them from restarting until you press "AI back on". It also ends Claude Remote Control sessions.',
      confirmLabel: 'Exam mode on',
      tone: 'danger',
    })) await act(examGuard.on);
  };
  const turnOff = async () => {
    if (await confirmAction({
      title: 'Turn the AI apps back on?',
      body: 'Only do this after your report is submitted. It restores the services, startup entries and loops that Exam mode turned off, on Kali and on the host.',
      confirmLabel: 'AI back on',
    })) await act(examGuard.off);
  };

  const active = !!st?.active;
  const until = st?.switch_at != null && !active ? st.switch_at - st.now : null;

  return (
    <section
      data-testid="exam-ai-lockdown"
      className={`rounded-xl border p-4 space-y-3 ${active ? 'bg-callout-danger-bg border-callout-danger-border' : 'bg-surface-card border-subtle'}`}
    >
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="text-sm font-semibold text-primary flex items-center gap-2">
          {active ? <ShieldOff className="w-4 h-4 text-callout-danger-fg" /> : <ShieldCheck className="w-4 h-4" />}
          Exam mode: AI lockdown
          <span className={`text-[11px] font-semibold px-1.5 py-0.5 rounded border ${active ? 'text-callout-danger-fg border-callout-danger-border' : 'text-muted border-subtle'}`}>
            {err ? 'BRIDGE OFFLINE' : active ? 'ON' : until != null ? `arms in ${fmtIn(until)}` : 'OFF'}
          </span>
        </h2>
        <div className="flex gap-2">
          {active ? (
            <CyberButton size="sm" variant="secondary" onClick={turnOff} disabled={busy || !!err} data-testid="exam-ai-off-btn"
              iconLeft={<Power className="w-3.5 h-3.5" />}>
              AI back on
            </CyberButton>
          ) : (
            <CyberButton size="sm" variant="danger" onClick={turnOn} disabled={busy || !!err} data-testid="exam-ai-on-btn"
              iconLeft={<ShieldOff className="w-3.5 h-3.5" />}>
              Exam mode on now
            </CyberButton>
          )}
        </div>
      </div>

      {err ? (
        <p className="text-xs text-callout-warn-fg">
          Can't reach hacktrack-bridge on 127.0.0.1:8790 ({err}). On Kali run{' '}
          <code className="font-mono">systemctl --user start hacktrack-bridge</code>, or install it from tools/hacktrack-bridge.
        </p>
      ) : (
        <>
          {!active && (
            <div className="flex flex-wrap items-end gap-3">
              <label className="text-xs text-muted flex flex-col gap-1">
                Exam starts
                <input
                  type="datetime-local"
                  value={startInput}
                  onChange={(e) => { setStartInput(e.target.value); setDirty(true); }}
                  className="rounded border border-subtle bg-surface-sunken px-2 py-1 text-primary text-sm"
                  data-testid="exam-ai-start"
                />
              </label>
              <label className="text-xs text-muted flex flex-col gap-1">
                Switch on (min before)
                <input
                  type="number"
                  min={0}
                  max={1440}
                  value={lead}
                  onChange={(e) => { setLead(Math.max(0, Math.min(1440, Number(e.target.value) || 0))); setDirty(true); }}
                  className="w-24 rounded border border-subtle bg-surface-sunken px-2 py-1 text-primary text-sm"
                  data-testid="exam-ai-lead"
                />
              </label>
              <CyberButton size="sm" variant="primary" onClick={saveSchedule} disabled={busy || !dirty} data-testid="exam-ai-save"
                iconLeft={<CalendarClock className="w-3.5 h-3.5" />}>
                {startInput ? 'Save schedule' : 'Clear schedule'}
              </CyberButton>
              {st?.switch_at != null && (
                <span className="text-xs text-muted">Switches on {fmtTime(st.switch_at)}</span>
              )}
            </div>
          )}
          {active && st && (
            <p className="text-xs text-callout-danger-fg">
              On since {fmtTime(st.activated_at)} ({st.activated_by === 'schedule' ? 'schedule' : 'manual'}). It stays on, re-checking every 2 minutes, until you press "AI back on".
            </p>
          )}
          {st && (
            <div className="space-y-1.5 border-t border-subtle pt-2">
              <SideLine label="Kali VM" s={st.kali} active={active} kind="kali" />
              <SideLine label="Windows host" s={st.host} active={active} kind="host" />
            </div>
          )}
        </>
      )}
    </section>
  );
};
