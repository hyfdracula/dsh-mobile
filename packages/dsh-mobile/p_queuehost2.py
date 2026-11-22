import io
P = "src/index.ts"
t = io.open(P, encoding="utf-8").read()
start = t.find("      const queueItemMatch = /^\\/api\\/sessions\\/([^/]+)\\/queue\\/([^/]+)\\/(drop|fire|edit)$/.exec(path)")
assert start > 0
end = t.find("      const sendMatch = /^\\/api\\/sessions\\/([^/]+)\\/send$/.exec(path)")
assert end > start
new = '''      const queueItemMatch = /^\\/api\\/sessions\\/([^/]+)\\/queue\\/([^/]+)\\/(drop|fire|edit)$/.exec(path)
      if (queueItemMatch !== null && method === 'POST') {
        const sessionId = decodeURIComponent(queueItemMatch[1])
        const itemId = decodeURIComponent(queueItemMatch[2])
        const action = queueItemMatch[3]
        const ctl = controller()
        if (!ctl || typeof ctl.updateQueue !== 'function') {
          send(res, 503, {
            error: 'sessionController.updateQueue unavailable',
            hint: 'restart the DSH host so the queue API is loaded',
          })
          return
        }
        let mutation: Record<string, unknown>
        if (action === 'edit') {
          const body = await readJson(req)
          const text = String(body.text ?? '').trim()
          if (text.length === 0) {
            send(res, 400, { error: 'text is empty' })
            return
          }
          mutation = { kind: 'edit', content: [{ type: 'text', text }] }
        } else if (action === 'drop') {
          mutation = { kind: 'remove' }
        } else {
          mutation = { kind: 'steer' }
        }
        const mutated = await hostMutate(ctl, sessionId, itemId, mutation)
        await record(logFile, `QUEUE ${action} session=${sessionId} id=${itemId} ok=${String(mutated)}`)
        if (!mutated) {
          send(res, 409, {
            error: 'queue item is no longer pending',
            queue: await hostQueueView(ctl, sessionId),
          })
          return
        }
        send(res, 200, {
          ok: true,
          sessionId,
          item: itemId,
          dropped: action === 'drop',
          fired: action === 'fire',
          queue: await hostQueueView(ctl, sessionId),
        })
        return
      }

'''
t = t[:start] + new + t[end:]
io.open(P, "w", encoding="utf-8", newline="\n").write(t)
print("part2 ok")
