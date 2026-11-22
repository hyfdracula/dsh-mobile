import io, re
P = "src/index.ts"
t = io.open(P, encoding="utf-8").read()

helpers = '''  // 排队交给宿主：桌面版输入区会显示「待发送」，手机端再用 updateQueue 改 / 删 / 插队。
  const hostState = async (ctl: any, sessionId: string): Promise<any> => {
    if (!ctl || typeof ctl.state !== 'function') return null
    try {
      return await Promise.resolve(ctl.state({ sessionId }, AbortSignal.timeout(8000)))
    } catch {
      return null
    }
  }

  const hostQueued = async (ctl: any, sessionId: string): Promise<any[]> => {
    const st = await hostState(ctl, sessionId)
    const q = st && Array.isArray(st.queue) ? st.queue : []
    return q.filter((it: any) => it !== null && typeof it === 'object' && it.placement === 'queued')
  }

  const hostText = (it: any): string => {
    const parts = it && Array.isArray(it.content) ? it.content : []
    return parts
      .filter((p: any) => p !== null && typeof p === 'object' && p.type === 'text')
      .map((p: any) => String(p.text ?? ''))
      .join(' ')
      .trim()
  }

  const hostQueueView = async (ctl: any, sessionId: string): Promise<Record<string, unknown>[]> => {
    const list = await hostQueued(ctl, sessionId)
    return list.map((it: any, i: number) => ({ id: String(it.id), text: hostText(it), at: 0, index: i + 1 }))
  }

  const hostEnqueue = async (
    ctl: any,
    sessionId: string,
    content: Record<string, unknown>[],
  ): Promise<string> => {
    const before = new Set((await hostQueued(ctl, sessionId)).map((x: any) => String(x.id)))
    await Promise.resolve(
      ctl.prompt(
        {
          requestId: randomBytes(16).toString('hex'),
          sessionId,
          mode: 'queue',
          content,
        },
        AbortSignal.timeout(30000),
      ),
    )
    const after = await hostQueued(ctl, sessionId)
    const fresh = after.find((x: any) => !before.has(String(x.id)))
    return fresh === undefined ? '' : String(fresh.id)
  }

  const hostMutate = async (
    ctl: any,
    sessionId: string,
    itemId: string,
    action: Record<string, unknown>,
  ): Promise<boolean> => {
    if (!ctl || typeof ctl.updateQueue !== 'function') return false
    try {
      await Promise.resolve(
        ctl.updateQueue({ sessionId, itemId, action }, AbortSignal.timeout(20000)),
      )
      return true
    } catch {
      return false
    }
  }

'''

anchor = "  const controller = (): any => {"
assert anchor in t
t = t.replace(anchor, helpers + anchor, 1)

# images queue branch
old = "          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }, ...parts], false)\n          await record(logFile, `200 POST images session=${sessionId} mode=queue local=${item.id} n=${String(parts.length)}`)"
new = "          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }, ...parts])\n          await record(logFile, `200 POST images session=${sessionId} mode=queue host=${itemId} n=${String(parts.length)}`)"
assert old in t
t = t.replace(old, new, 1)
t = t.replace("""            item: item.id,
            count: parts.length,
            queue: queueView(sessionId),""", """            item: itemId,
            count: parts.length,
            queue: await hostQueueView(ctl, sessionId),""", 1)

# files queue branch
old = "          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }], false)\n          await record(logFile, `200 POST files session=${sessionId} mode=queue local=${item.id} n=${String(saved.length)}`)"
new = "          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])\n          await record(logFile, `200 POST files session=${sessionId} mode=queue host=${itemId} n=${String(saved.length)}`)"
assert old in t
t = t.replace(old, new, 1)
t = t.replace("""            item: item.id,
            count: saved.length,
            files: saved,
            queue: queueView(sessionId),""", """            item: itemId,
            count: saved.length,
            files: saved,
            queue: await hostQueueView(ctl, sessionId),""", 1)

# send queue branch
old = """        if (effective === 'queue' && running) {
          // 队列留在插件这一层：宿主没有「撤回排队消息」的接口，
          // 一旦交给它就永远改不了。放这里才能编辑 / 删除 / 插队，
          // 会话空下来后由 drainQueues() 逐条送进去。
          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }], false)
          await record(logFile, `200 POST send session=${sessionId} mode=queue local=${item.id}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: item.id,
            queue: queueView(sessionId),
          })
          return
        }"""
new = """        if (effective === 'queue' && running) {
          // 交给宿主排队（桌面版输入区能看到「待发送」），手机端改 / 删 / 插队走
          // sessionController.updateQueue。
          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          await record(logFile, `200 POST send session=${sessionId} mode=queue host=${itemId}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: itemId,
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }"""
assert old in t
t = t.replace(old, new, 1)

# messages: drop mirror cleanup, host queue view
old_mirror = t[t.find("        // 宿主队列里的那条真正发出来以后，手机端的镜像就撤掉（按文本匹配，取最后 60 条）。"):]
old_mirror = old_mirror[: old_mirror.find("        send(res, 200, {")]
assert old_mirror != ""
t = t.replace(old_mirror, "", 1)
t = t.replace("          queue: queueView(sessionId),\n          questions: pendingAsks(listed, sessionId),", "          queue: await hostQueueView(ctl, sessionId),\n          questions: pendingAsks(listed, sessionId),", 1)

# queue GET/POST
old = """        if (method === 'GET') {
          send(res, 200, { ok: true, sessionId, queue: queueView(sessionId) })
          return
        }"""
new = """        if (method === 'GET') {
          const ctl = controller()
          send(res, 200, { ok: true, sessionId, queue: await hostQueueView(ctl, sessionId) })
          return
        }"""
assert old in t
t = t.replace(old, new, 1)

old = """          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }], false)
          await record(logFile, `200 QUEUE push session=${sessionId} local=${item.id}`)
          send(res, 200, {
            ok: true,
            sessionId,
            item: item.id,
            queue: queueView(sessionId),
          })"""
new = """          const itemId = await hostEnqueue(ctl, sessionId, [{ type: 'text', text }])
          await record(logFile, `200 QUEUE push session=${sessionId} host=${itemId}`)
          send(res, 200, {
            ok: true,
            sessionId,
            item: itemId,
            queue: await hostQueueView(ctl, sessionId),
          })"""
assert old in t
t = t.replace(old, new, 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(t)
print("part1 ok")
