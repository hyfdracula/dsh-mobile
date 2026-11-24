/**
 * The "用户反馈" section of the DSH settings dialog.
 *
 * It reads the ticket list through the host half (`/api/dsh-mobile/panel/feedback/*`),
 * which holds the admin key on this machine only. A machine without that key gets
 * `configured: false`, and this component then renders nothing at all — so shipping
 * the plugin does not expose anybody's tickets.
 * @module @deepseek-ai/dsh-mobile/client/FeedbackSection
 */
import { useCallback, useEffect, useState } from 'react'

/** One ticket as the worker returns it. */
interface Ticket {
  id: string
  kind: string
  title: string
  body: string
  status: string
  env: string
  contact: string
  created_at: number
  updated_at: number
  files: { name: string; kind: string; size: number }[]
  replies: { author: string; text: string; at: number }[]
}

interface State {
  configured: boolean
  tickets?: Ticket[]
  summary?: { counts?: { status: string; n: number }[] }
  error?: string
}

const C = {
  card: 'var(--dsw-alias-bg-layer-3, #ffffff)',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,.24))',
  fg: 'var(--dsw-alias-label-primary, #1b1d21)',
  fgDim: 'var(--dsw-alias-label-secondary, #5c6270)',
  fgFaint: 'var(--dsw-alias-label-tertiary, #8a90a0)',
  accent: 'var(--dsw-alias-state-business-primary, #1a6ef0)',
  ok: 'var(--dsw-alias-state-success-primary, #1a9a5e)',
  bad: 'var(--dsw-alias-state-error-primary, #d4380d)',
}

const ROUTE = 'api/dsh-mobile/panel/feedback'

const STATUS: Record<string, { label: string; color: string }> = {
  open: { label: '待处理', color: C.accent },
  doing: { label: '处理中', color: C.accent },
  done: { label: '已完成', color: C.ok },
  wontfix: { label: '不处理', color: C.fgFaint },
}

const KIND: Record<string, string> = {
  bug: '问题反馈',
  feature: '功能建议',
  ux: '体验问题',
  other: '其他',
}

const stamp = (ms: number): string => {
  const d = new Date(ms)
  const two = (n: number): string => (n < 10 ? `0${n}` : String(n))
  return `${d.getMonth() + 1}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`
}

async function post(path: string, body: unknown): Promise<void> {
  const res = await fetch(`${ROUTE}/${path}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    const text = await res.text()
    throw new Error(text.slice(0, 200))
  }
}

/** The panel section. */
export function FeedbackSection(): React.ReactElement | null {
  const [state, setState] = useState<State | null>(null)
  const [seen, setSeen] = useState(false)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [reply, setReply] = useState<Record<string, string>>({})
  const [open, setOpen] = useState('')

  const load = useCallback(async (): Promise<void> => {
    try {
      const res = await fetch(`${ROUTE}/state`, { cache: 'no-store' })
      const data = (await res.json()) as State
      setState(data)
      setError(data.error ?? '')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setSeen(true)
    }
  }, [])

  useEffect(() => {
    void load()
    const timer = setInterval(() => { void load() }, 30000)
    return () => clearInterval(timer)
  }, [load])

  if (!seen || state === null || state.configured !== true) {
    return null
  }

  const act = async (id: string, work: () => Promise<void>): Promise<void> => {
    setBusy(id)
    setError('')
    try {
      await work()
      await load()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusy('')
    }
  }

  const tickets = state.tickets ?? []
  const counts = state.summary?.counts ?? []

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10 }}>
        <span style={{ fontSize: 13, color: C.fgDim }}>共 {tickets.length} 条</span>
        {counts.map((one) => (
          <span key={one.status} style={{ fontSize: 12, color: STATUS[one.status]?.color ?? C.fgFaint }}>
            {STATUS[one.status]?.label ?? one.status} {one.n}
          </span>
        ))}
        <span style={{ flex: 1 }} />
        <button
          type="button"
          onClick={() => { void load() }}
          style={{
            fontSize: 12,
            padding: '4px 10px',
            borderRadius: 8,
            border: `1px solid ${C.border}`,
            background: 'transparent',
            color: C.fgDim,
            cursor: 'pointer',
          }}
        >
          刷新
        </button>
      </div>

      {tickets.length === 0
        ? <div style={{ fontSize: 12, color: C.fgFaint }}>还没有人反馈。</div>
        : null}

      {tickets.map((t) => {
        const st = STATUS[t.status] ?? { label: t.status, color: C.fgFaint }
        const expanded = open === t.id
        return (
          <div
            key={t.id}
            style={{
              border: `1px solid ${C.border}`,
              background: C.card,
              borderRadius: 12,
              padding: '12px 14px',
              display: 'flex',
              flexDirection: 'column',
              gap: 8,
            }}
          >
            <div
              style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }}
              onClick={() => setOpen(expanded ? '' : t.id)}
            >
              <span style={{ fontSize: 11, color: C.fgFaint }}>{t.id}</span>
              <span style={{ fontSize: 11, color: C.fgDim }}>{KIND[t.kind] ?? t.kind}</span>
              <span style={{ fontSize: 11, color: C.fgFaint }}>{stamp(t.created_at)}</span>
              <span style={{ flex: 1 }} />
              <span style={{ fontSize: 11, color: st.color }}>{st.label}</span>
            </div>
            <div style={{ fontSize: 13, color: C.fg, fontWeight: 500 }}>{t.title}</div>
            {expanded
              ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                  <div style={{ fontSize: 12.5, color: C.fg, whiteSpace: 'pre-wrap', lineHeight: 1.65 }}>{t.body}</div>
                  <div style={{ fontSize: 11, color: C.fgFaint }}>运行环境：{t.env === '' ? '（未采集）' : t.env}</div>
                  {t.contact !== ''
                    ? <div style={{ fontSize: 11, color: C.fgFaint }}>联系方式：{t.contact}</div>
                    : null}
                  {t.files.length > 0
                    ? (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                        {t.files.map((f) => (
                          <a
                            key={f.name}
                            href={`${ROUTE}/file?id=${encodeURIComponent(t.id)}&name=${encodeURIComponent(f.name)}`}
                            style={{
                              fontSize: 11,
                              color: C.accent,
                              border: `1px solid ${C.border}`,
                              borderRadius: 8,
                              padding: '2px 8px',
                              textDecoration: 'none',
                            }}
                          >
                            {f.name} · {f.size >= 1024 * 1024
                              ? `${(f.size / 1024 / 1024).toFixed(1)} MB`
                              : `${Math.max(1, Math.round(f.size / 1024))} KB`}
                          </a>
                        ))}
                      </div>
                    )
                    : null}
                  {t.replies.length > 0
                    ? (
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                        {t.replies.map((r, i) => (
                          <div key={`${t.id}-${String(i)}`} style={{ fontSize: 12, color: C.fgDim }}>
                            <span style={{ color: r.author === 'admin' ? C.accent : C.fgFaint }}>
                              {r.author === 'admin' ? '我' : '用户'} · {stamp(r.at)}：
                            </span>
                            {r.text}
                          </div>
                        ))}
                      </div>
                    )
                    : null}
                  <textarea
                    value={reply[t.id] ?? ''}
                    onChange={(e) => setReply({ ...reply, [t.id]: e.target.value })}
                    placeholder="回一句，或者留空只改状态"
                    rows={2}
                    style={{
                      width: '100%',
                      boxSizing: 'border-box',
                      fontSize: 12.5,
                      padding: '8px 10px',
                      borderRadius: 9,
                      border: `1px solid ${C.border}`,
                      background: 'transparent',
                      color: C.fg,
                      resize: 'vertical',
                    }}
                  />
                  <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    <button
                      type="button"
                      disabled={busy === t.id}
                      onClick={() => {
                        const text = (reply[t.id] ?? '').trim()
                        if (text === '') return
                        void act(t.id, async () => {
                          await post('reply', { id: t.id, text })
                          setReply({ ...reply, [t.id]: '' })
                        })
                      }}
                      style={btn(true)}
                    >
                      回复
                    </button>
                    {['doing', 'done', 'wontfix', 'open'].map((next) => (
                      <button
                        key={next}
                        type="button"
                        disabled={busy === t.id || t.status === next}
                        onClick={() => {
                          void act(t.id, async () => { await post('status', { id: t.id, status: next }) })
                        }}
                        style={btn(false)}
                      >
                        {STATUS[next]?.label ?? next}
                      </button>
                    ))}
                  </div>
                </div>
              )
              : null}
          </div>
        )
      })}

      {error.length > 0
        ? <div style={{ fontSize: 12, color: C.bad }}>出错了：{error}</div>
        : null}
    </div>
  )
}

function btn(primary: boolean): React.CSSProperties {
  return {
    fontSize: 12,
    padding: '5px 12px',
    borderRadius: 8,
    border: `1px solid ${primary ? C.accent : C.border}`,
    background: primary ? C.accent : 'transparent',
    color: primary ? '#ffffff' : C.fgDim,
    cursor: 'pointer',
  }
}
