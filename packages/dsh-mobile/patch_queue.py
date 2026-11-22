import io
P = r"C:\Users\19161\Documents\dsh-work\packages\dsh-mobile\src\index.ts"
t = io.open(P, encoding="utf-8").read()

# --- send ---
old = """        if (effective === 'queue' && running) {
          // \u4ea4\u7ed9\u5bbf\u4e3b\u63a7\u5236\u5668\u6392\u961f\uff1a\u684c\u9762\u7aef\u7684\u8f93\u5165\u533a\u4f1a\u628a\u5b83\u663e\u793a\u6210\u5f85\u53d1\u9001\uff0c\u56de\u5408\u7ed3\u675f\u540e\u81ea\u52a8\u53d1\u51fa\u3002
          // \u624b\u673a\u7aef\u53ea\u7559\u4e00\u4efd\u955c\u50cf\uff08host=true\uff09\uff0c\u7528\u6765\u5c55\u793a\u300c\u7535\u8111\u4e0a\u6392\u7740\u4ec0\u4e48\u300d\u3002
          const hostResult = await Promise.resolve(
            ctl.prompt(
              {
                requestId: randomBytes(16).toString('hex'),
                sessionId,
                mode: 'queue',
                content: [{ type: 'text', text }],
              },
              AbortSignal.timeout(20000),
            ),
          )
          const mirror = enqueuePrompt(sessionId, text, [{ type: 'text', text }], true)
          await record(logFile, `200 POST send session=${sessionId} mode=queue host=true mirror=${mirror.id}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: mirror.id,
            queue: queueView(sessionId),
            result: hostResult ?? null,
          })
          return
        }"""
assert old in t, "send block"
new = """        if (effective === 'queue' && running) {
          // \u961f\u5217\u7559\u5728\u63d2\u4ef6\u8fd9\u4e00\u5c42\uff1a\u5bbf\u4e3b\u6ca1\u6709\u300c\u64a4\u56de\u6392\u961f\u6d88\u606f\u300d\u7684\u63a5\u53e3\uff0c
          // \u4e00\u65e6\u4ea4\u7ed9\u5b83\u5c31\u6c38\u8fdc\u6539\u4e0d\u4e86\u3002\u653e\u8fd9\u91cc\u624d\u80fd\u7f16\u8f91 / \u5220\u9664 / \u63d2\u961f\uff0c
          // \u4f1a\u8bdd\u7a7a\u4e0b\u6765\u540e\u7531 drainQueues() \u9010\u6761\u9001\u8fdb\u53bb\u3002
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
t = t.replace(old, new, 1)

# --- images ---
old_img = """        if (mode === 'queue' && running) {
          const hostResult = await Promise.resolve(
            ctl.prompt(
              {
                requestId: randomBytes(16).toString('hex'),
                sessionId,
                mode: 'queue',
                content: [{ type: 'text', text }, ...parts],
              },
              AbortSignal.timeout(60000),
            ),
          )
          const mirror = enqueuePrompt(sessionId, text, [{ type: 'text', text }, ...parts], true)
          await record(logFile, `200 POST images session=${sessionId} mode=queue host=true mirror=${mirror.id} n=${String(parts.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: mirror.id,
            count: parts.length,
            queue: queueView(sessionId),
            result: hostResult ?? null,
          })
          return
        }"""
assert old_img in t, "images block"
new_img = """        if (mode === 'queue' && running) {
          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }, ...parts], false)
          await record(logFile, `200 POST images session=${sessionId} mode=queue local=${item.id} n=${String(parts.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: item.id,
            count: parts.length,
            queue: queueView(sessionId),
          })
          return
        }"""
t = t.replace(old_img, new_img, 1)

# --- files ---
old_f = """        if (mode === 'queue' && running) {
          const hostResult = await Promise.resolve(
            ctl.prompt(
              {
                requestId: randomBytes(16).toString('hex'),
                sessionId,
                mode: 'queue',
                content: [{ type: 'text', text }],
              },
              AbortSignal.timeout(60000),
            ),
          )
          const mirror = enqueuePrompt(sessionId, text, [{ type: 'text', text }], true)
          await record(logFile, `200 POST files session=${sessionId} mode=queue host=true mirror=${mirror.id} n=${String(saved.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: mirror.id,
            count: saved.length,
            files: saved,
            queue: queueView(sessionId),
            result: hostResult ?? null,
          })
          return
        }"""
assert old_f in t, "files block"
new_f = """        if (mode === 'queue' && running) {
          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }], false)
          await record(logFile, `200 POST files session=${sessionId} mode=queue local=${item.id} n=${String(saved.length)}`)
          send(res, 200, {
            ok: true,
            sessionId,
            mode: 'queue',
            queued: true,
            item: item.id,
            count: saved.length,
            files: saved,
            queue: queueView(sessionId),
          })
          return
        }"""
t = t.replace(old_f, new_f, 1)

# --- manual queue push ---
old_push = """          const hostResult = await Promise.resolve(
            ctl.prompt(
              {
                requestId: randomBytes(16).toString('hex'),
                sessionId,
                mode: 'queue',
                content: [{ type: 'text', text }],
              },
              AbortSignal.timeout(20000),
            ),
          )
          const mirror = enqueuePrompt(sessionId, text, [{ type: 'text', text }], true)
          await record(logFile, `200 QUEUE push session=${sessionId} host=true mirror=${mirror.id}`)
          send(res, 200, {
            ok: true,
            sessionId,
            item: mirror.id,
            queue: queueView(sessionId),
            result: hostResult ?? null,
          })
          return"""
assert old_push in t, "push block"
new_push = """          const item = enqueuePrompt(sessionId, text, [{ type: 'text', text }], false)
          await record(logFile, `200 QUEUE push session=${sessionId} local=${item.id}`)
          send(res, 200, {
            ok: true,
            sessionId,
            item: item.id,
            queue: queueView(sessionId),
          })
          return"""
t = t.replace(old_push, new_push, 1)

# --- route regex: 支持 edit ---
t = t.replace("/queue/([^/]+)/(drop|fire)$/.exec(path)", "/queue/([^/]+)/(drop|fire|edit)$/.exec(path)", 1)
t = t.replace("const action = queueItemMatch[3]", "const action = queueItemMatch[3]", 1)

# --- edit 实现：插到 dump 分支之前 ---
anchor = """        if (action === 'drop') {"""
assert anchor in t
edit_branch = """        if (action === 'edit') {
          const body = await readJson(req)
          const text = String(body.text ?? '').trim()
          if (text.length === 0) {
            send(res, 400, { error: 'text is empty' })
            return
          }
          const list = queueList(sessionId)
          const hit = list.find((q) => q.id === itemId)
          if (hit === undefined) {
            send(res, 404, { error: 'queue item not found', queue: queueView(sessionId) })
            return
          }
          hit.text = text
          hit.content = [{ type: 'text', text }]
          await record(logFile, `200 QUEUE edit session=${sessionId} id=${itemId} bytes=${String(Buffer.byteLength(text))}`)
          send(res, 200, { ok: true, sessionId, item: itemId, queue: queueView(sessionId) })
          return
        }
""" + anchor
t = t.replace(anchor, edit_branch, 1)

io.open(P, "w", encoding="utf-8", newline="\n").write(t)
print("plugin patched")
