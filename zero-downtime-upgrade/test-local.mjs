// The upgrade with no TEE: a fake dstack socket, the server from docker-compose.yaml, a stand-in
// gateway, and client.mjs running throughout. Ends by restarting the new writer.
import http from 'node:http'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawn } from 'node:child_process'

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zdt-'))
const compose = fs.readFileSync(new URL('./docker-compose.yaml', import.meta.url), 'utf8').split('\n')
const server = path.join(dir, 'server.mjs')
fs.writeFileSync(server, compose.slice(compose.indexOf('    content: |') + 1).map(l => l.slice(6)).join('\n'))
const sock = path.join(dir, 'dstack.sock')
// The real guest agent decodes a body without this content type as protobuf and fails.
http.createServer((req, res) => req.headers['content-type'] !== 'application/json' ? res.writeHead(400).end()
  : res.end(JSON.stringify(req.url === '/GetKey' ? { key: '11'.repeat(32) } : { instance_id: 'local' }))).listen(sock)

const sleep = ms => new Promise(r => setTimeout(r, ms))
const status = port => fetch('http://127.0.0.1:' + port + '/_status').then(r => r.json())
const procs = {}
function run(name, port, env) {
  fs.mkdirSync(path.join(dir, name), { recursive: true })
  procs[name] = spawn('node', [server], { env: { ...process.env, PORT: String(port), DSTACK_SOCK: sock, DATA_FILE: path.join(dir, name, 'kv.json'), ...env } })
  procs[name].stdout.on('data', d => process.stdout.write(name + ': ' + d))
  procs[name].stderr.on('data', d => process.stdout.write(name + '! ' + d))
}

// Like dstack-gateway, the stand-in rotates over every instance of the app, writer or not, and
// skips one whose port refuses the connection (a CVM that is rebooting).
const backends = [8101]
let rr = 0
http.createServer(async (req, res) => {
  let body = ''
  for await (const d of req) body += d
  const first = rr++
  for (let i = 0; i < backends.length; i++) {
    try {
      const r = await fetch('http://127.0.0.1:' + backends.at((first + i) % backends.length) + req.url, { method: req.method, body: req.method === 'GET' ? undefined : body })
      res.writeHead(r.status)
      return res.end(Buffer.from(await r.arrayBuffer()))
    } catch (e) {
      if (e.cause?.code !== 'ECONNREFUSED') { res.writeHead(599); return res.end(e.message) }
    }
  }
  res.writeHead(599)
  res.end('no instance accepted the connection')
}).listen(8100)

const b = { PREDECESSOR_URL: 'http://127.0.0.1:8101', SELF_URL: 'http://127.0.0.1:8102' }
run('a', 8101, { APP_VERSION: '1' })
await sleep(500)
const client = spawn('node', [new URL('./client.mjs', import.meta.url).pathname, 'http://127.0.0.1:8100'])
let out = ''
client.stdout.on('data', d => { out += d; process.stdout.write('client: ' + d) })
await sleep(2000)

console.log('--- B boots dormant, like a fresh replica, and the gateway starts sending it traffic')
run('b', 8102, { ...b, DORMANT: '1' })
await sleep(300)
backends.push(8102)
await sleep(1500)
const dormant = await status(8102)
console.log('--- B restarts on the new compose and takes over')
procs.b.kill()
await sleep(300)
run('b', 8102, { ...b, APP_VERSION: '2' })
await sleep(3000)
const sa = await status(8101), sb = await status(8102)
console.log('A', sa, 'B', sb)
console.log('--- A is removed')
backends.shift()
await sleep(1000)
procs.a.kill()
await sleep(2000)
client.kill('SIGINT')
await sleep(300)
const stats = JSON.parse(out.trim().split('\n').at(-1))

console.log('--- B restarts; its env still names the stopped A as its predecessor')
procs.b.kill()
await sleep(300)
run('b', 8102, { ...b, APP_VERSION: '2' })
await sleep(500)
const restarted = await status(8102)
console.log('restarted B', restarted)
Object.values(procs).forEach(p => p.kill())

const pass = stats.ok > 30 && stats.fail === 0 && stats.regressions === 0 && dormant.role === 'follower' && sa.role === 'retired'
  && sb.role === 'writer' && sb.app === '2' && restarted.role === 'writer' && restarted.version === stats.lastVersion
console.log(pass ? 'PASS' : 'FAIL')
process.exit(pass ? 0 : 1)
