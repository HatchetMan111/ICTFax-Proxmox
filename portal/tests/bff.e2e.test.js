import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { setTimeout as sleep } from 'node:timers/promises'
import { fileURLToPath } from 'node:url'

// End-to-end test for the Express BFF against a mock of the ICTCore REST API.
//
// Regression: the portal used to POST /api/token_payload after login. ICTCore
// has no such endpoint (the upstream Angular client only calls it for SAML
// login), so the probe returned 404, /api/session deleted the freshly issued
// cookie and every following request failed with 401. The mock therefore
// answers 404 on purpose.

const MOCK_TOKEN = 'mock.jwt.token'

const DIST_INDEX = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  '..',
  'dist',
  'index.html',
)

function startMock() {
  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1')
    const path = url.pathname
    const json = (code, body) => {
      const payload = JSON.stringify(body)
      res.writeHead(code, {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      })
      res.end(payload)
    }
    const readBody = () =>
      new Promise((resolve) => {
        const chunks = []
        req.on('data', (c) => chunks.push(c))
        req.on('end', () => resolve(Buffer.concat(chunks)))
      })

    if (path === '/api/authenticate' && req.method === 'POST') {
      const body = JSON.parse((await readBody()).toString() || '{}')
      if (body.username === 'admin' && body.password === 'helloAdmin') {
        return json(200, {
          user_id: 1,
          username: 'admin',
          email: 'admin@ictcore.org',
          token: MOCK_TOKEN,
          access_token: MOCK_TOKEN,
        })
      }
      return json(401, { error: { code: 401, message: 'Invalid user name and password' } })
    }

    // Deliberately absent upstream.
    if (path === '/api/token_payload') {
      return json(404, { error: { code: 404, message: 'Invalid API location' } })
    }

    if ((req.headers.authorization || '') !== `Bearer ${MOCK_TOKEN}`) {
      return json(401, { error: { code: 401, message: 'Invalid credentials' } })
    }

    if (path === '/api/statistics' && req.method === 'GET') {
      return json(200, {
        user_total: 2,
        did_total: 1,
        transmission_inbound: 0,
        transmission_outbound: 1,
      })
    }

    if (path === '/api/accounts' && req.method === 'GET') {
      return json(200, [
        { account_id: 1, name: 'Trunk', phone: '4930123456', type: 'cid' },
        { account_id: 2, name: 'DID', phone: '004930123456', type: 'did' },
      ])
    }

    if (path === '/api/providers' && req.method === 'GET') {
      return json(200, [{ provider_id: 1, name: 'SIP', type: 'sip' }])
    }

    if (path === '/api/transmissions' && req.method === 'GET') {
      const direction = url.searchParams.get('direction') || 'outbound'
      return json(
        200,
        direction === 'outbound'
          ? [
              {
                transmission_id: 100,
                title: 'Testfax',
                phone: '+4930123456',
                status: 'completed',
                last_run: 1700000000,
              },
            ]
          : [],
      )
    }

    if (path === '/api/transmissions' && req.method === 'POST') {
      return json(200, 100)
    }

    if (/^\/api\/transmissions\/\d+\/send$/.test(path) && req.method === 'POST') {
      return json(200, { spool_id: 901 })
    }

    if (/^\/api\/transmissions\/\d+\/results$/.test(path)) {
      return json(200, [{ name: 'document', data: 7 }])
    }

    if (path === '/api/documents' && req.method === 'POST') {
      return json(200, 7)
    }

    const media = path.match(/^\/api\/documents\/(\d+)\/media$/)
    if (media) {
      if (req.method === 'POST' || req.method === 'PUT') {
        await readBody()
        return json(200, Number(media[1]))
      }
      const pdf = Buffer.from('%PDF-1.4\n% mock\n%%EOF\n')
      res.writeHead(200, { 'Content-Type': 'application/pdf', 'Content-Length': pdf.length })
      return res.end(pdf)
    }

    if (path === '/api/programs/sendfax' && req.method === 'POST') {
      return json(200, 10)
    }

    return json(404, { error: { code: 404, message: `no mock route ${path}` } })
  })

  return new Promise((resolve, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => resolve(server))
  })
}

test('BFF end-to-end against a mock ICTFax', async (t) => {
  let mock = null
  let server = null

  try {
    mock = await startMock()
    const mockPort = mock.address().port

    process.env.ICTFAX_API_URL = `http://127.0.0.1:${mockPort}/api`
    process.env.SESSION_SECRET = 'e2e-test-secret'
    process.env.ICTFAX_PUBLIC_URL = `http://127.0.0.1:${mockPort}`
    process.env.PORTAL_LOG = '0'

    // Import after the env is in place: the module captures the upstream URL at
    // load time.
    const { createApp } = await import('../server/index.js')
    const app = createApp()
    server = await new Promise((resolve, reject) => {
      const s = app.listen(0, '127.0.0.1', () => resolve(s))
      s.once('error', reject)
    })
    const base = `http://127.0.0.1:${server.address().port}`

    const cookies = new Map()
    async function call(path, options = {}) {
      const res = await fetch(`${base}${path}`, {
        method: options.method || 'GET',
        headers: {
          ...(cookies.size
            ? { Cookie: [...cookies].map(([k, v]) => `${k}=${v}`).join('; ') }
            : {}),
          ...(options.headers || {}),
        },
        body: options.body,
        redirect: 'manual',
      })
      for (const c of res.headers.getSetCookie?.() || []) {
        const pair = c.split(';')[0]
        const eq = pair.indexOf('=')
        const name = pair.slice(0, eq)
        const value = pair.slice(eq + 1)
        // Express' clearCookie only writes Expires (Thu, 01 Jan 1970), no Max-Age=0.
        const expires = c.match(/Expires=([^;]+)/i)
        const expired =
          /Max-Age=0/i.test(c) ||
          (expires && !Number.isNaN(Date.parse(expires[1])) && Date.parse(expires[1]) <= Date.now())
        if (!value || expired) cookies.delete(name)
        else cookies.set(name, value)
      }
      const type = res.headers.get('content-type') || ''
      const data = options.raw
        ? Buffer.from(await res.arrayBuffer())
        : type.includes('application/json')
          ? await res.json()
          : await res.text()
      return { status: res.status, data }
    }

    await t.test('health', async () => {
      const r = await call('/api/health')
      assert.equal(r.status, 200)
      assert.equal(r.data.status, 'ok')
    })

    await t.test('anonymous session', async () => {
      const r = await call('/api/session')
      assert.equal(r.status, 200)
      assert.equal(r.data.authenticated, false)
    })

    await t.test('login sets session cookies', async () => {
      const r = await call('/api/session/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'admin', password: 'helloAdmin' }),
      })
      assert.equal(r.status, 200)
      assert.equal(r.data.ok, true)
      assert.equal(r.data.user.username, 'admin')
      assert.ok(cookies.has('ictfax_token'), 'token cookie must be set')
      assert.ok(cookies.has('ictfax_profile'), 'profile cookie must be set')
    })

    await t.test('session survives a reload', async () => {
      const r = await call('/api/session')
      assert.equal(r.status, 200)
      assert.equal(r.data.authenticated, true)
      assert.equal(r.data.user.username, 'admin')
    })

    await t.test('dashboard after login', async () => {
      const r = await call('/api/dashboard')
      assert.equal(r.status, 200)
      assert.equal(r.data.outbound.length, 1)
      assert.equal(r.data.stats.transmission_outbound, 1)
    })

    await t.test('send fax', async () => {
      const form = new FormData()
      form.append('account_id', '1')
      form.append('phone', '+49 (30) 1234-5678')
      form.append('title', 'Mein Testfax')
      form.append('quality', 'superfine')
      form.append('file', new Blob([Buffer.from('%PDF-1.4\n')], { type: 'application/pdf' }), 'test.pdf')
      const r = await call('/api/fax/send', { method: 'POST', body: form })
      assert.equal(r.status, 200)
      assert.equal(r.data.transmission_id, 100)
      assert.equal(r.data.spool_id, 901)
    })

    await t.test('setup/readiness report', async () => {
      const r = await call('/api/setup')
      assert.equal(r.status, 200)
      assert.deepEqual(r.data.checks, {
        backend: true,
        caller_id: true,
        did: true,
        sip: true,
      })
      assert.equal(r.data.accounts.cid, 1)
      assert.equal(r.data.accounts.did, 1)
      assert.equal(r.data.providers.total, 1)
    })

    await t.test('document download', async () => {
      const r = await call('/api/transmissions/100/document', { raw: true })
      assert.equal(r.status, 200)
      assert.equal(r.data.slice(0, 4).toString(), '%PDF')
    })

    await t.test('rejects an invalid phone number', async () => {
      const form = new FormData()
      form.append('account_id', '1')
      form.append('phone', '123')
      form.append('file', new Blob(['x'], { type: 'application/pdf' }), 'x.pdf')
      const r = await call('/api/fax/send', { method: 'POST', body: form })
      assert.equal(r.status, 400)
      assert.match(r.data.error, /Faxnummer/)
    })

    await t.test('login failure returns 401', async () => {
      const r = await call('/api/session/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: 'admin', password: 'nope' }),
      })
      assert.equal(r.status, 401)
      assert.match(r.data.error, /Invalid user name and password/)
    })

    await t.test('logout clears the session', async () => {
      const r = await call('/api/session/logout', { method: 'POST' })
      assert.equal(r.status, 200)
      assert.equal(cookies.size, 0)
      const s = await call('/api/session')
      assert.equal(s.data.authenticated, false)
    })

    await t.test('static build is served for SPA deep links', async (ctx) => {
      if (!fs.existsSync(DIST_INDEX)) {
        ctx.skip('dist/index.html fehlt – npm run build vorher ausführen')
        return
      }
      const res = await fetch(`${base}/transmissions`)
      const body = await res.text()
      assert.equal(res.status, 200)
      assert.match(body, /<div id="root">/)
    })
  } finally {
    // Undici keeps sockets alive; close() alone would wait for them forever.
    server?.closeAllConnections?.()
    mock?.closeAllConnections?.()
    if (server) await new Promise((resolve) => server.close(resolve))
    if (mock) await new Promise((resolve) => mock.close(resolve))
    await sleep(10)
  }
})