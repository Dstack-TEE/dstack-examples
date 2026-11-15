// Runs the handover with no TEE: a fake dstack socket, two copies of the server from
// docker-compose.yaml, and a round-robin proxy standing in for the gateway. A client loop
// writes and reads through the proxy with no retries for the whole upgrade.
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zdt-'))
const compose = fs.readFileSync(new URL('./docker-compose.yaml', import.meta.url), 'utf8').split('\n')
const start = compose.indexOf('    content: |') + 1
fs.writeFileSync(path.join(dir, 'server.mjs'), compose.slice(start).map(l => l.slice(6)).join('\n'))

const sock = path.join(dir, 'dstack.sock')
http.createServer((req, res) => {
  res.setHeader('content-type', 'application/json')
  if (req.url === '/GetKey') return res.end(JSON.stringify({ key: '11'.repeat(32) }))
  res.end(JSON.stringify({ instance_id: 'local' }))
}).listen(sock)

const procs = []
function run(name, port, extra) {
  fs.mkdirSync(path.join(dir, name), { recursive: true })
  const p = spawn('node', [path.join(dir, 'server.mjs')], { env: { ...process.env, PORT: String(port),
    DSTACK_SOCK: sock, DATA_FILE: path.join(dir, name, 'kv.json'), ...extra } })
  p.stdout.on('data', d => process.stdout.write(name + ': ' + d))
  p.stderr.on('data', d => process.stdout.write(name + '! ' + d))
  procs.push(p)
}

// The gateway stand-in rotates over every registered instance, healthy or not, so an instance
// that has not taken over yet still gets traffic. Like dstack-gateway's connect_multiple_hosts, it
// skips an instance whose port refuses the connection (a CVM that is rebooting).
const backends = [8101]
let rr = 0
http.createServer(async (req, res) => {
  let body = ''
  for await (const d of req) body += d
  const start = rr++
  for (let i = 0; i < backends.length; i++) {
    const port = backends[(start + i) % backends.length]
    try {
      const r = await fetch('http://127.0.0.1:' + port + req.url, { method: req.method, body: req.method === 'GET' ? undefined : body })
      res.writeHead(r.status)
      return res.end(Buffer.from(await r.arrayBuffer()))
    } catch (e) {
      if (e.cause?.code !== 'ECONNREFUSED') { res.writeHead(599); return res.end(e.message) }
    }
  }
  res.writeHead(599)
  res.end('no instance accepted the connection')
}).listen(8100)

const sleep = ms => new Promise(r => setTimeout(r, ms))
const stats = { ok: 0, fail: 0, maxMs: 0, lastVersion: 0, regressions: 0 }
let running = true
async function client() {
  for (let i = 1; running; i++) {
    const t = Date.now()
    try {
      const w = await fetch('http://127.0.0.1:8100/kv/counter', { method: 'PUT', body: String(i) })
      const r = await fetch('http://127.0.0.1:8100/kv/counter')
      const got = await r.json()
      if (w.status !== 200 || r.status !== 200 || got.value !== String(i)) throw new Error(w.status + ' ' + r.status + ' ' + JSON.stringify(got))
      if (got.version < stats.lastVersion) stats.regressions++
      stats.lastVersion = got.version
      stats.ok++
    } catch (e) {
      stats.fail++
      console.log('client failure:', e.message)
    }
    stats.maxMs = Math.max(stats.maxMs, Date.now() - t)
    await sleep(20)
  }
}

run('a', 8101, { APP_VERSION: '1' })
await sleep(500)
const loop = client()
await sleep(2000)
console.log('--- starting B dormant, as a fresh replica boots; the proxy sends half the traffic to it')
const b = { PREDECESSOR_URL: 'http://127.0.0.1:8101', SELF_URL: 'http://127.0.0.1:8102' }
run('b-dormant', 8102, { ...b, DORMANT: '1' })
await sleep(300)
backends.push(8102)
await sleep(1500)
const dormant = await (await fetch('http://127.0.0.1:8102/_status')).json()
console.log('dormant B', dormant)
console.log('--- restarting B with the new compose; the proxy keeps it in rotation while it is down')
procs[1].kill()
await sleep(300)
run('b', 8102, { ...b, APP_VERSION: '2' })
await sleep(3000)
const sa = await (await fetch('http://127.0.0.1:8101/_status')).json()
const sb = await (await fetch('http://127.0.0.1:8102/_status')).json()
console.log('A', sa, 'B', sb)
console.log('--- removing A from the proxy, then stopping it')
backends.shift()
await sleep(1000)
procs[0].kill()
await sleep(2000)
running = false
await loop
console.log('client', stats)
console.log('--- restarting B, whose env still names the stopped A as its predecessor')
procs[2].kill()
await sleep(300)
run('b', 8102, { ...b, APP_VERSION: '2' })
await sleep(500)
const restarted = await (await fetch('http://127.0.0.1:8102/_status')).json()
const value = await (await fetch('http://127.0.0.1:8100/kv/counter')).json()
console.log('restarted B', restarted, value)
procs.forEach(p => p.kill())
const pass = stats.fail === 0 && stats.regressions === 0 && dormant.role === 'follower' && sa.role === 'retired' && sb.role === 'writer' && sb.app === '2' && stats.ok > 50
  && restarted.role === 'writer' && value.version === stats.lastVersion
console.log(pass ? 'PASS' : 'FAIL')
process.exit(pass ? 0 : 1)
