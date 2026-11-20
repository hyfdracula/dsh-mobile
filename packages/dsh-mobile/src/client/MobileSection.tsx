/**
 * The "手机连接" section of the DSH settings dialog.
 *
 * It is a thin view over the host half's pairing routes: show the live six
 * digit code, the QR a phone scans, which paths are offered, and whether a
 * phone has checked in recently. Nothing here is authoritative — every write
 * goes back to the host and the answer replaces the local copy.
 * @module @deepseek-ai/dsh-mobile/client/MobileSection
 */
import { useCallback, useEffect, useState, type ReactNode } from 'react'

/** The pairing snapshot the host returns. */
interface PanelState {
  ok: boolean
  host: string
  version: string
  port: number
  code: string
  expiresAt: number
  allowLan: boolean
  allowRemote: boolean
  publicUrl: string
  lan: string[]
  base: string
  payload: string
  phoneSeenAt: number
  phoneOnline: boolean
}

/** The design tokens the DSH shell publishes, with light-theme fallbacks. */
const C = {
  card: 'var(--dsw-alias-bg-layer-3, #ffffff)',
  cardSoft: 'var(--dsw-alias-bg-layer-1, #ffffff)',
  border: 'var(--dsw-alias-border-l2, rgba(127,127,127,.24))',
  fg: 'var(--dsw-alias-label-primary, #1b1d21)',
  fgDim: 'var(--dsw-alias-label-secondary, #5c6270)',
  fgFaint: 'var(--dsw-alias-label-tertiary, #8a90a0)',
  accent: 'var(--dsw-alias-state-business-primary, #1a6ef0)',
  ok: 'var(--dsw-alias-state-success-primary, #1a9a5e)',
  bad: 'var(--dsw-alias-state-error-primary, #d4380d)',
}

const ROUTE = 'api/dsh-mobile/panel'

/** Read one JSON answer, turning a non-2xx into a readable error. */
async function getJson(path: string): Promise<PanelState> {
  const res = await fetch(path, { credentials: 'same-origin', cache: 'no-store' })
  if (!res.ok) throw new Error(`HTTP ${String(res.status)}`)
  return (await res.json()) as PanelState
}

/** Post a JSON patch and read the resulting state back. */
async function postJson(path: string, body: unknown): Promise<PanelState> {
  const res = await fetch(path, {
    method: 'POST',
    credentials: 'same-origin',
    cache: 'no-store',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`HTTP ${String(res.status)}`)
  return (await res.json()) as PanelState
}

/** One bordered card. */
function Card(props: { children: ReactNode }): ReactNode {
  return (
    <div style={{
      border: `1px solid ${C.border}`,
      background: C.card,
      borderRadius: 12,
      padding: '14px 16px',
    }}
    >
      {props.children}
    </div>
  )
}

/** A card title row with an optional trailing chip. */
function Title(props: { text: string; chip?: ReactNode }): ReactNode {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 6 }}>
      <span style={{ fontSize: 14, fontWeight: 600, color: C.fg }}>{props.text}</span>
      {props.chip}
    </div>
  )
}

/** A small status chip. */
function Chip(props: { text: string; tone: 'ok' | 'idle' | 'bad' }): ReactNode {
  const color = props.tone === 'ok' ? C.ok : props.tone === 'bad' ? C.bad : C.fgFaint
  return (
    <span style={{
      display: 'inline-flex',
      alignItems: 'center',
      gap: 5,
      fontSize: 12,
      color,
      background: 'rgba(127,127,127,.10)',
      borderRadius: 999,
      padding: '2px 9px',
    }}
    >
      <span style={{ width: 6, height: 6, borderRadius: 3, background: color }} />
      {props.text}
    </span>
  )
}

/** A labelled row. */
function Row(props: { label: string; value: ReactNode }): ReactNode {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12, padding: '6px 0' }}>
      <span style={{ fontSize: 13, color: C.fgDim }}>{props.label}</span>
      <span style={{ fontSize: 13, color: C.fg, textAlign: 'right' }}>{props.value}</span>
    </div>
  )
}

/** A pill toggle. */
function Toggle(props: { on: boolean; onChange: (next: boolean) => void; disabled?: boolean }): ReactNode {
  const width = 40
  const height = 22
  return (
    <button
      type="button"
      role="switch"
      aria-checked={props.on}
      disabled={props.disabled === true}
      onClick={() => { if (props.disabled !== true) props.onChange(!props.on) }}
      style={{
        width,
        height,
        borderRadius: height / 2,
        border: 'none',
        padding: 0,
        cursor: props.disabled === true ? 'default' : 'pointer',
        background: props.on ? C.accent : 'rgba(127,127,127,.32)',
        position: 'relative',
        transition: 'background .18s ease',
        flex: '0 0 auto',
      }}
    >
      <span style={{
        position: 'absolute',
        top: 2,
        left: props.on ? width - height + 2 : 2,
        width: height - 4,
        height: height - 4,
        borderRadius: '50%',
        background: '#ffffff',
        boxShadow: '0 1px 2px rgba(0,0,0,.25)',
        transition: 'left .18s cubic-bezier(.34,1.4,.64,1)',
      }}
      />
    </button>
  )
}

/** A compact button. */
function Btn(props: { text: string; onClick: () => void; primary?: boolean; disabled?: boolean }): ReactNode {
  const primary = props.primary === true
  return (
    <button
      type="button"
      disabled={props.disabled === true}
      onClick={props.onClick}
      style={{
        border: primary ? 'none' : `1px solid ${C.border}`,
        background: primary ? C.accent : 'transparent',
        color: primary ? '#ffffff' : C.fg,
        borderRadius: 8,
        padding: '6px 12px',
        fontSize: 13,
        cursor: props.disabled === true ? 'default' : 'pointer',
        opacity: props.disabled === true ? 0.55 : 1,
        flex: '0 0 auto',
      }}
    >
      {props.text}
    </button>
  )
}

/** Format the seconds a code still lives as `mm:ss`. */
function countdown(secondsLeft: number): string {
  const safe = Math.max(0, secondsLeft)
  const mm = Math.floor(safe / 60)
  const ss = safe % 60
  return `${String(mm).padStart(2, '0')}:${String(ss).padStart(2, '0')}`
}

/**
 * Render the pairing section.
 * @returns the section element.
 */
export function MobileSection(): ReactNode {
  const [state, setState] = useState<PanelState | null>(null)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState('')
  const [draftUrl, setDraftUrl] = useState('')
  const [copied, setCopied] = useState('')
  const [now, setNow] = useState(Date.now())

  /** Pull the live state; a failure keeps the last good copy on screen. */
  const load = useCallback(async (): Promise<void> => {
    try {
      const next = await getJson(`${ROUTE}/state`)
      setState(next)
      setError('')
      setDraftUrl((current) => current.length > 0 ? current : next.publicUrl)
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    }
  }, [])

  useEffect(() => {
    void load()
    const poll = setInterval(() => {
      if (typeof document !== 'undefined' && document.visibilityState === 'hidden') return
      void load()
    }, 5000)
    const clock = setInterval(() => { setNow(Date.now()) }, 1000)
    return () => {
      clearInterval(poll)
      clearInterval(clock)
    }
  }, [load])

  /** Apply one patch through the host and adopt its answer. */
  const patch = useCallback(async (key: string, body: unknown): Promise<void> => {
    setBusy(key)
    try {
      const next = await postJson(`${ROUTE}/config`, body)
      setState(next)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [])

  /** Mint a fresh code. */
  const rotate = useCallback(async (): Promise<void> => {
    setBusy('code')
    try {
      const next = await postJson(`${ROUTE}/newcode`, {})
      setState(next)
      setError('')
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
    } finally {
      setBusy('')
    }
  }, [])

  /** Copy text to the clipboard and flash the source label. */
  const copy = useCallback(async (text: string, label: string): Promise<void> => {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(label)
      setTimeout(() => { setCopied('') }, 1600)
    } catch {
      setCopied('')
    }
  }, [])

  const online = state?.phoneOnline === true
  const secondsLeft = state === null ? 0 : Math.floor((state.expiresAt - now) / 1000)
  const qrSrc = state === null || state.payload.length === 0
    ? ''
    : `${ROUTE}/qr.svg?payload=${encodeURIComponent(state.payload)}`

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      <div style={{ fontSize: 13, color: C.fgDim }}>
        手机扫码就能连上这台电脑的 DSH。配对码一次性，用过即换；手机和电脑要在同一个 WiFi。
      </div>

      <Card>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{
              width: 34,
              height: 34,
              borderRadius: 9,
              background: 'rgba(26,110,240,.12)',
              color: C.accent,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              fontSize: 12,
              fontWeight: 700,
            }}
            >
              DSH
            </div>
            <div>
              <div style={{ fontSize: 14, fontWeight: 600, color: C.fg }}>DSH 手机连接</div>
              <div style={{ fontSize: 12, color: C.fgFaint }}>
                DeepSeek Harness · {state?.host ?? '-'}
              </div>
            </div>
          </div>
          <Chip text={online ? '手机已连接' : '等待手机连接'} tone={online ? 'ok' : 'idle'} />
        </div>
      </Card>

      <Card>
        <Title text="允许连接" />
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 0' }}>
          <div>
            <div style={{ fontSize: 13, color: C.fg }}>局域网直连</div>
            <div style={{ fontSize: 12, color: C.fgFaint }}>同一 WiFi 下 App 直接连这台电脑</div>
          </div>
          <Toggle
            on={state?.allowLan === true}
            disabled={busy === 'lan'}
            onChange={(next) => { void patch('lan', { allowLan: next }) }}
          />
        </div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 0' }}>
          <div>
            <div style={{ fontSize: 13, color: C.fg }}>公网访问</div>
            <div style={{ fontSize: 12, color: C.fgFaint }}>手机在外网时连隧道地址，电脑需常驻</div>
          </div>
          <Toggle
            on={state?.allowRemote === true}
            disabled={busy === 'remote'}
            onChange={(next) => { void patch('remote', { allowRemote: next }) }}
          />
        </div>
        {state !== null && state.allowLan && state.lan.length > 0
          ? (
            <div style={{ marginTop: 8 }}>
              <div style={{ fontSize: 12, color: C.fgFaint, marginBottom: 4 }}>本机地址（点一下复制）</div>
              <button
                type="button"
                onClick={() => { void copy(state.lan[0] as string, 'lan') }}
                style={{
                  border: `1px solid ${C.border}`,
                  background: C.cardSoft,
                  color: C.fg,
                  borderRadius: 8,
                  padding: '5px 10px',
                  fontSize: 12,
                  cursor: 'pointer',
                }}
              >
                {copied === 'lan' ? '已复制' : String(state.lan[0])}
              </button>
            </div>
          )
          : null}
        {state !== null && state.allowRemote
          ? (
            <div style={{ marginTop: 8 }}>
              <div style={{ fontSize: 12, color: C.fgFaint, marginBottom: 4 }}>公网地址</div>
              <div style={{ display: 'flex', gap: 8 }}>
                <input
                  value={draftUrl}
                  placeholder="https://dsh.example.net"
                  onChange={(event) => { setDraftUrl(event.target.value) }}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    border: `1px solid ${C.border}`,
                    borderRadius: 8,
                    background: C.cardSoft,
                    color: C.fg,
                    padding: '6px 10px',
                    fontSize: 13,
                  }}
                />
                <Btn
                  text={busy === 'url' ? '保存中' : '保存'}
                  disabled={busy === 'url'}
                  onClick={() => { void patch('url', { publicUrl: draftUrl }) }}
                />
              </div>
            </div>
          )
          : null}
      </Card>

      <Card>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
          <span style={{ fontSize: 14, fontWeight: 600, color: C.fg }}>扫码连接</span>
          <Btn text="换一个新码" disabled={busy === 'code'} onClick={() => { void rotate() }} />
        </div>
        {qrSrc.length > 0
          ? (
            <div style={{ display: 'flex', justifyContent: 'center' }}>
              <img
                alt="配对二维码"
                src={qrSrc}
                width={200}
                height={200}
                style={{ background: '#ffffff', padding: 9, borderRadius: 12 }}
              />
            </div>
          )
          : (
            <div style={{ fontSize: 12, color: C.fgFaint }}>
              还没有可用地址：打开上面的「局域网直连」，或填一个公网地址。
            </div>
          )}
      </Card>

      <Card>
        <Title text="6 位配对码" />
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 4 }}>
          <div style={{
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
            fontSize: 26,
            letterSpacing: 6,
            fontWeight: 600,
            color: C.fg,
          }}
          >
            {state?.code ?? '------'}
          </div>
          <span style={{ fontSize: 12, color: secondsLeft > 60 ? C.fgFaint : C.bad }}>
            剩余 {countdown(secondsLeft)}
          </span>
        </div>
        <div style={{ fontSize: 12, color: C.fgFaint, marginTop: 6 }}>
          手机 App 里输入这 6 位数字即可配对；用过一次自动换新码。
        </div>
      </Card>

      {state !== null
        ? (
          <Card>
            <Row label="插件版本" value={`v${state.version}`} />
            <Row label="网关端口" value={String(state.port)} />
            <Row label="当前二维码地址" value={state.base.length > 0 ? state.base : '未配置'} />
          </Card>
        )
        : null}

      {error.length > 0
        ? <div style={{ fontSize: 12, color: C.bad }}>状态读取失败：{error}</div>
        : null}
    </div>
  )
}
