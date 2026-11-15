// Writes then reads a counter through the app URL forever, with no retries and a fresh
// connection per request, and prints every failure. Ctrl-C prints the summary.
// Usage: node client.mjs https://<app_id>-8080.<gateway base>
import https from 'node:https'

const base = process.argv[2]
const req = (method, path, body) => new Promise((resolve, reject) => {
  const r = https.request(base + path, { method, agent: false, timeout: 10000 }, res => {
    let s = ''
    res.on('data', d => { s += d })
    res.on('end', () => resolve({ status: res.statusCode, body: s }))
  })
  r.on('timeout', () => r.destroy(new Error('timeout')))
  r.on('error', reject)
  r.end(body)
})

const stats = { ok: 0, fail: 0, regressions: 0, maxMs: 0, lastVersion: 0, firstFail: null, lastFail: null }
process.on('SIGINT', () => { console.log(JSON.stringify(stats)); process.exit(0) })
for (let i = Date.now(); ; i++) {
  const t = Date.now()
  try {
    const w = await req('PUT', '/kv/counter', String(i))
    const r = await req('GET', '/kv/counter')
    if (w.status !== 200 || r.status !== 200) throw new Error(w.status + ' ' + w.body + ' / ' + r.status + ' ' + r.body)
    const got = JSON.parse(r.body)
    if (got.value !== String(i)) throw new Error('read ' + got.value + ' after writing ' + i)
    if (got.version < stats.lastVersion) stats.regressions++
    stats.lastVersion = got.version
    if (++stats.ok % 50 === 0) console.log(new Date().toISOString(), JSON.stringify(stats))
  } catch (e) {
    stats.fail++
    stats.firstFail ??= new Date(t).toISOString()
    stats.lastFail = new Date(t).toISOString()
    console.log(new Date(t).toISOString(), 'FAIL', e.message)
  }
  const ms = Date.now() - t
  stats.maxMs = Math.max(stats.maxMs, ms)
  await new Promise(r => setTimeout(r, 100))
}
