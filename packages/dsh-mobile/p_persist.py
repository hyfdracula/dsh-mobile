import io
P = r"C:\Users\19161\Documents\dsh-work\packages\dsh-mobile\src\index.ts"
t = io.open(P, encoding="utf-8").read()

anchor = "  const promptQueues = new Map<string, QueuedPrompt[]>()\n"
assert anchor in t
block = anchor + """
  // \u6392\u961f\u8981\u6d3b\u5f97\u6bd4\u8fdb\u7a0b\u4e45\uff1a\u5bbf\u4e3b\u91cd\u542f\u4e0d\u5e94\u8be5\u628a\u7528\u6237\u6392\u7740\u7684\u8bdd\u4e22\u6389\u3002
  const queueFile = (): string => join(dshHome(), 'queue.json')
  let queueSaveTimer: ReturnType<typeof setTimeout> | undefined

  const flushQueue = (): void => {
    try {
      const out: Record<string, QueuedPrompt[]> = {}
      promptQueues.forEach((list, sid) => {
        if (list.length > 0) out[sid] = list
      })
      writeFileSync(queueFile(), JSON.stringify(out), { mode: 0o600 })
    } catch {
      /* \u961f\u5217\u843d\u76d8\u5931\u8d25\u4e0d\u5f71\u54cd\u53d1\u9001 */
    }
  }

  const saveQueue = (): void => {
    if (queueSaveTimer !== undefined) clearTimeout(queueSaveTimer)
    queueSaveTimer = setTimeout(() => {
      queueSaveTimer = undefined
      flushQueue()
    }, 200)
  }

  const loadQueue = (): void => {
    try {
      const parsed = JSON.parse(readFileSync(queueFile(), 'utf8')) as Record<string, QueuedPrompt[]>
      for (const sid of Object.keys(parsed)) {
        const list = parsed[sid]
        if (Array.isArray(list) && list.length > 0) promptQueues.set(sid, list)
      }
    } catch {
      /* \u9996\u6b21\u542f\u52a8\u6ca1\u6709\u961f\u5217\u6587\u4ef6 */
    }
  }

  loadQueue()
"""
t = t.replace(anchor, block, 1)

t = t.replace("""    promptQueues.set(sessionId, list)
    return item
  }""", """    promptQueues.set(sessionId, list)
    saveQueue()
    return item
  }""", 1)

t = t.replace("""    if (list.length === 0) promptQueues.delete(sessionId)
    else promptQueues.set(sessionId, list)
    return one ?? null""", """    if (list.length === 0) promptQueues.delete(sessionId)
    else promptQueues.set(sessionId, list)
    saveQueue()
    return one ?? null""", 1)

t = t.replace("""          hit.text = text
          hit.content = [{ type: 'text', text }]""", """          hit.text = text
          hit.content = [{ type: 'text', text }]
          saveQueue()""", 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(t)
print("persistence patched")
