/**
 * DSH 设置对话框中的「用户反馈」管理面板（仅本机持有管理员密钥时注册显示）。
 * @module @deepseek-ai/dsh-mobile/client/FeedbackSection
 */
import { useCallback, useEffect, useState, type CSSProperties, type ReactElement } from 'react'

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
  card: 'var(--dsw-alias-surface-card, var(--dsw-alias-bg-layer-3, rgba(127,127,127,0.08)))',
  cardSoft: 'var(--dsw-alias-bg-layer-2, var(--dsw-alias-bg-layer-1, rgba(127,127,127,0.06)))',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,0.24))',
  fg: 'var(--dsw-alias-label-primary, currentColor)',
  fgDim: 'var(--dsw-alias-label-secondary, rgba(127,127,127,0.85))',
  fgFaint: 'var(--dsw-alias-label-tertiary, rgba(127,127,127,0.68))',
  accent: 'var(--dsw-alias-state-business-primary, #1a6ef0)',
  onAccent: 'var(--dsw-alias-label-on-color, #f8fafc)',
  ok: 'var(--dsw-alias-state-success-primary, #1a9a5e)',
  bad: 'var(--dsw-alias-state-error-primary, #d4380d)',
  badBg: 'rgba(212,56,13,0.10)',
}

const ROUTE = '/api/dsh-mobile/panel/feedback'

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
  const two = (n: number): string => (n < 10 ? `0${String(n)}` : String(n))
  return `${String(d.getMonth() + 1)}-${two(d.getDate())} ${two(d.getHours())}:${two(d.getMinutes())}`
}

async function readErrorMessage(res: Response): Promise<string> {
  const text = await res.text()
  if (text.length > 0) {
    try {
      const parsed: unknown = JSON.parse(text)
      if (parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed)) {
        const err = (parsed as Record<string, unknown>).error
        if (typeof err === 'string' && err.trim().length > 0) return err.trim()
      }
    } catch {
      // fallback to plain slice
    }
    return text.slice(0, 200)
  }
  return `HTTP ${String(res.status)}`
}

async function post(path: string, body: unknown): Promise<void> {
  const res = await fetch(`${ROUTE}/${path}`, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'content-type': 'application/json; charset=utf-8' },
    body: JSON.stringify(body),
  })
  if (!res.ok) {
    throw new Error(await readErrorMessage(res))
  }
}

function btn(primary: boolean, disabled: boolean): CSSProperties {
  return {
    fontSize: 12,
    fontFamily: 'inherit',
    lineHeight: 1.45,
    padding: '5px 12px',
    borderRadius: 8,
    border: `1px solid ${primary ? C.accent : C.border}`,
    background: primary ? C.accent : 'transparent',
    color: primary ? C.onAccent : C.fgDim,
    cursor: disabled ? 'default' : 'pointer',
    opacity: disabled ? 0.5 : 1,
    flexShrink: 0,
    whiteSpace: 'nowrap',
  }
}

export function FeedbackSection(): ReactElement | null {
  const [state, setState] = useState<State | null>(null)
  const [seen, setSeen] = useState(false)
  const [loading, setLoading] = useState(false)
  const [busy, setBusy] = useState('')
  const [error, setError] = useState('')
  const [reply, setReply] = useState<Record<string, string>>({})
  const [open, setOpen] = useState('')

  const load = useCallback(async (): Promise<void> => {
    setLoading(true)
    try {
      const res = await fetch(`${ROUTE}/state`, { credentials: 'same-origin', cache: 'no-store' })
      if (!res.ok) {
        const msg = await readErrorMessage(res)
        setError(msg)
        setState((prev) => prev ?? { configured: true, tickets: [] })
        return
      }
      const data = (await res.json()) as State
      setState(data)
      setError(data.error ?? '')
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
      setSeen(true)
    }
  }, [])

  useEffect(() => {
    void load()
    const timer = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      void load()
    }, 30000)
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
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12, minWidth: 0 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap', minWidth: 0 }}>
        <span style={{ fontSize: 13, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>
          共 {String(tickets.length)} 条
        </span>
        {counts.map((one) => (
          <span
            key={one.status}
            style={{
              fontSize: 12,
              color: STATUS[one.status]?.color ?? C.fgFaint,
              flexShrink: 0,
              whiteSpace: 'nowrap',
            }}
          >
            {STATUS[one.status]?.label ?? one.status} {String(one.n)}
          </span>
        ))}
        <span style={{ flex: 1 }} />
        <button
          type="button"
          disabled={loading}
          onClick={() => { void load() }}
          style={{
            fontSize: 12,
            fontFamily: 'inherit',
            lineHeight: 1.45,
            padding: '4px 10px',
            borderRadius: 8,
            border: `1px solid ${C.border}`,
            background: 'transparent',
            color: C.fgDim,
            cursor: loading ? 'default' : 'pointer',
            opacity: loading ? 0.5 : 1,
            flexShrink: 0,
            whiteSpace: 'nowrap',
          }}
        >
          ↻ 刷新
        </button>
      </div>

      {error.length > 0
        ? (
          <div
            role="alert"
            style={{
              border: `1px solid ${C.bad}`,
              background: C.badBg,
              color: C.bad,
              borderRadius: 10,
              padding: '9px 12px',
              fontSize: 12.5,
              lineHeight: 1.45,
              minWidth: 0,
              overflowWrap: 'anywhere',
              wordBreak: 'break-word',
            }}
          >
            出错了：{error}
          </div>
        )
        : null}

      {tickets.length === 0
        ? <div style={{ fontSize: 12, color: C.fgFaint }}>还没有人反馈。</div>
        : null}

      {tickets.map((t) => {
        const st = STATUS[t.status] ?? { label: t.status, color: C.fgFaint }
        const expanded = open === t.id
        const replyText = (reply[t.id] ?? '').trim()
        const replyDisabled = busy === t.id || replyText === ''
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
              minWidth: 0,
            }}
          >
            <div
              role="button"
              tabIndex={0}
              onClick={() => { setOpen(expanded ? '' : t.id) }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  setOpen(expanded ? '' : t.id)
                }
              }}
              style={{ display: 'flex', flexDirection: 'column', gap: 6, cursor: 'pointer', minWidth: 0 }}
            >
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', minWidth: 0 }}>
                <span style={{ fontSize: 12, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>
                  {expanded ? '▾' : '▸'}
                </span>
                <span style={{ fontSize: 11, color: C.fgFaint, flexShrink: 0, whiteSpace: 'nowrap' }}>{t.id}</span>
                <span style={{ fontSize: 11, color: C.fgDim, flexShrink: 0, whiteSpace: 'nowrap' }}>{KIND[t.kind] ?? t.kind}</span>
                <span style={{ fontSize: 11, color: C.fgFaint, flexShrink: 0, whiteSpace: 'nowrap' }}>{stamp(t.created_at)}</span>
                <span style={{ flex: 1 }} />
                <span style={{
                  fontSize: 11,
                  color: st.color,
                  background: 'rgba(127,127,127,0.10)',
                  borderRadius: 999,
                  padding: '1px 8px',
                  flexShrink: 0,
                  whiteSpace: 'nowrap',
                }}
                >
                  {st.label}
                </span>
              </div>
              <div style={{
                fontSize: 13,
                color: C.fg,
                fontWeight: 500,
                minWidth: 0,
                overflowWrap: 'anywhere',
                wordBreak: 'break-word',
              }}
              >
                {t.title}
              </div>
            </div>

            {expanded
              ? (
                <div style={{ display: 'flex', flexDirection: 'column', gap: 8, minWidth: 0 }}>
                  <div style={{
                    fontSize: 12.5,
                    color: C.fg,
                    whiteSpace: 'pre-wrap',
                    lineHeight: 1.65,
                    minWidth: 0,
                    overflowWrap: 'anywhere',
                    wordBreak: 'break-word',
                  }}
                  >
                    {t.body}
                  </div>
                  <div style={{ fontSize: 11, color: C.fgFaint, minWidth: 0, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                    运行环境：{t.env === '' ? '（未采集）' : t.env}
                  </div>
                  {t.contact !== ''
                    ? (
                      <div style={{ fontSize: 11, color: C.fgFaint, minWidth: 0, overflowWrap: 'anywhere', wordBreak: 'break-word' }}>
                        联系方式：{t.contact}
                      </div>
                    )
                    : null}
                  {t.files.length > 0
                    ? (
                      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, minWidth: 0 }}>
                        {t.files.map((f) => (
                          <a
                            key={f.name}
                            href={`${ROUTE}/file?id=${encodeURIComponent(t.id)}&name=${encodeURIComponent(f.name)}`}
                            style={{
                              fontSize: 11,
                              color: C.accent,
                              border: `1px solid ${C.border}`,
                              background: C.cardSoft,
                              borderRadius: 8,
                              padding: '2px 8px',
                              textDecoration: 'none',
                              maxWidth: '100%',
                              minWidth: 0,
                              overflowWrap: 'anywhere',
                              wordBreak: 'break-word',
                            }}
                          >
                            {f.name} · {f.size >= 1024 * 1024
                              ? `${(f.size / 1024 / 1024).toFixed(1)} MB`
                              : `${String(Math.max(1, Math.round(f.size / 1024)))} KB`}
                          </a>
                        ))}
                      </div>
                    )
                    : null}
                  {t.replies.length > 0
                    ? (
                      <div style={{ display: 'flex', flexDirection: 'column', gap: 6, minWidth: 0 }}>
                        {t.replies.map((r, i) => (
                          <div
                            key={`${t.id}-${String(i)}`}
                            style={{
                              fontSize: 12,
                              color: C.fgDim,
                              minWidth: 0,
                              overflowWrap: 'anywhere',
                              wordBreak: 'break-word',
                            }}
                          >
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
                    onChange={(e) => { setReply({ ...reply, [t.id]: e.target.value }) }}
                    placeholder="回复内容（留空时仅可切换右侧状态）"
                    rows={2}
                    style={{
                      width: '100%',
                      minWidth: 0,
                      boxSizing: 'border-box',
                      fontSize: 12.5,
                      fontFamily: 'inherit',
                      lineHeight: 1.45,
                      padding: '8px 10px',
                      borderRadius: 9,
                      border: `1px solid ${C.border}`,
                      background: C.cardSoft,
                      color: C.fg,
                      resize: 'vertical',
                    }}
                  />
                  <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                    <button
                      type="button"
                      disabled={replyDisabled}
                      onClick={() => {
                        if (replyDisabled) return
                        void act(t.id, async () => {
                          await post('reply', { id: t.id, text: replyText })
                          setReply({ ...reply, [t.id]: '' })
                        })
                      }}
                      style={btn(true, replyDisabled)}
                    >
                      回复
                    </button>
                    {['doing', 'done', 'wontfix', 'open'].map((next) => {
                      const stDisabled = busy === t.id || t.status === next
                      return (
                        <button
                          key={next}
                          type="button"
                          disabled={stDisabled}
                          onClick={() => {
                            if (stDisabled) return
                            void act(t.id, async () => { await post('status', { id: t.id, status: next }) })
                          }}
                          style={btn(false, stDisabled)}
                        >
                          {STATUS[next]?.label ?? next}
                        </button>
                      )
                    })}
                  </div>
                </div>
              )
              : null}
          </div>
        )
      })}
    </div>
  )
}
