import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import express from 'express'
import cookieParser from 'cookie-parser'
import multer from 'multer'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const DIST_DIR = path.resolve(__dirname, '..', 'dist')

function loadConfigFile() {
  const candidates = [
    process.env.PORTAL_CONFIG,
    '/etc/ictfax-portal/config.env',
  ].filter(Boolean)
  for (const file of candidates) {
    try {
      const text = fs.readFileSync(file, 'utf8')
      for (const line of text.split('\n')) {
        const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$/)
        if (!m) continue
        let value = m[2]
        if (
          (value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))
        ) {
          value = value.slice(1, -1)
        }
        if (process.env[m[1]] === undefined) process.env[m[1]] = value
      }
      return file
    } catch {
      // systemd EnvironmentFile may already have supplied everything
    }
  }
  return null
}

const configFile = loadConfigFile()
const API_BASE = (process.env.ICTFAX_API_URL || 'http://127.0.0.1:8081/api').replace(/\/+$/, '')
const PORT = Number(process.env.PORT || 8080)
const SESSION_SECRET = process.env.SESSION_SECRET || ''
const COOKIE_SECURE = process.env.COOKIE_SECURE === '1'
const NODE_ENV = process.env.NODE_ENV || 'development'
const LOG_REQUESTS = process.env.PORTAL_LOG !== '0'

if (NODE_ENV === 'production' && !SESSION_SECRET) {
  console.error('[portal] FATAL: SESSION_SECRET is missing.')
  process.exit(1)
}
const SECRET = SESSION_SECRET || crypto.randomBytes(32).toString('hex')

const COOKIE_OPTS = {
  httpOnly: true,
  sameSite: 'lax',
  secure: COOKIE_SECURE,
  signed: true,
  path: '/',
  maxAge: 12 * 60 * 60 * 1000,
}

const MIME_TO_EXT = {
  'application/pdf': 'pdf',
  'image/tiff': 'tif',
  'image/tif': 'tif',
  'image/png': 'png',
  'image/jpeg': 'jpg',
  'image/jpg': 'jpg',
}

export function normalizePhone(raw) {
  if (typeof raw !== 'string') return ''
  const trimmed = raw.trim()
  const plus = trimmed.startsWith('+')
  let digits = trimmed.replace(/\D/g, '')
  if (digits.length < 5 || digits.length > 20) return ''
  const international = plus || digits.startsWith('00')
  if (digits.startsWith('00')) digits = digits.slice(2)
  return international ? `+${digits}` : digits
}

function asList(data) {
  if (Array.isArray(data)) return data
  if (Array.isArray(data?.data)) return data.data
  if (Array.isArray(data?.rows)) return data.rows
  return []
}

export function safeMessage(data, fallback) {
  if (!data) return fallback
  if (typeof data === 'string') return data.slice(0, 300)
  if (typeof data !== 'object') return fallback
  if (typeof data.message === 'string' && data.message) return data.message.slice(0, 300)
  const err = data.error
  if (typeof err === 'string' && err) return err.slice(0, 300)
  if (err && typeof err === 'object' && typeof err.message === 'string' && err.message) {
    return err.message.slice(0, 300)
  }
  return fallback
}

// ICTCore accepts basic|standard|fine|super|superior|ultra (see
// ICT\Core\Message\Document::set_quality). "superfine" is silently ignored
// upstream and would fall back to 204x98, so it is not offered.
const QUALITIES = ['basic', 'standard', 'fine', 'super', 'superior', 'ultra']

async function apiFetch(pathname, options = {}) {
  const {
    token,
    method = 'GET',
    body,
    headers = {},
    timeout = 30000,
    raw = false,
  } = options
  const h = { Accept: 'application/json', ...headers }
  if (token) h.Authorization = `Bearer ${token}`
  let payload
  if (body !== undefined && body !== null) {
    if (Buffer.isBuffer(body) || typeof body === 'string') {
      payload = body
    } else {
      payload = JSON.stringify(body)
      h['Content-Type'] = h['Content-Type'] || 'application/json'
    }
  }
  const res = await fetch(`${API_BASE}${pathname}`, {
    method,
    headers: h,
    body: payload,
    signal: AbortSignal.timeout(timeout),
  })
  if (raw) return { res, data: null }
  const text = await res.text()
  let data = null
  if (text) {
    try {
      data = JSON.parse(text)
    } catch {
      data = text
    }
  }
  return { res, data, text }
}

async function apiJson(pathname, options = {}) {
  const { res, data, text } = await apiFetch(pathname, options)
  if (!res.ok) {
    const err = new Error(safeMessage(data, `Upstream ${res.status}`))
    err.status = res.status
    err.upstream = data || text
    throw err
  }
  return data
}

function readToken(req) {
  return req.signedCookies?.ictfax_token || null
}

function clearSessionCookies(res) {
  const opts = { ...COOKIE_OPTS, maxAge: undefined }
  res.clearCookie('ictfax_token', opts)
  res.clearCookie('ictfax_profile', opts)
}

function readProfile(req) {
  const raw = req.signedCookies?.ictfax_profile
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw)
    return parsed && typeof parsed === 'object' ? parsed : null
  } catch {
    return null
  }
}

// The JWT is signed by ICTCore (RS256). We only read the payload to show the
// user name without an extra round trip; every real API call still carries the
// token and is verified by ICTCore itself.
function decodeJwtPayload(token) {
  try {
    const part = String(token).split('.')[1]
    if (!part) return null
    const json = Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8')
    return JSON.parse(json)
  } catch {
    return null
  }
}

function profileFromUser(data, fallbackUsername) {
  const name = [data?.first_name, data?.last_name].filter(Boolean).join(' ').trim()
  return {
    username: data?.username || data?.email || fallbackUsername || null,
    email: data?.email || null,
    user_id: data?.user_id ?? null,
    name: name || null,
    is_admin: data?.is_admin ?? null,
  }
}

// ICTCore has no /token_payload endpoint (the upstream Angular client only
// calls it for SAML login). Probing it returned 404 and the portal used to
// delete a perfectly valid session cookie because of that. Verify the token
// against a real authenticated endpoint instead.
//   true  -> token accepted
//   false -> token rejected (expired, revoked, wrong password)
//   null  -> ICTFax unreachable, keep the session (signed cookie, UI stays up)
async function verifyToken(token) {
  try {
    const { res } = await apiFetch('/statistics', { token, timeout: 8000 })
    if (res.ok) return true
    if (res.status === 401 || res.status === 403) return false
    return null
  } catch {
    return null
  }
}

function requireAuth(req, res, next) {
  const token = readToken(req)
  if (!token) return res.status(401).json({ error: 'Nicht angemeldet' })
  req.ictfaxToken = token
  next()
}

async function createDocument(token, file, fields) {
  const ext = MIME_TO_EXT[file.mimetype]
  if (!ext) {
    const err = new Error('Nur PDF, TIFF, PNG oder JPEG werden unterstützt.')
    err.status = 415
    throw err
  }
  const name = (fields.title || file.originalname || 'Fax').toString().slice(0, 120)
  const quality = QUALITIES.includes(fields.quality) ? fields.quality : 'standard'
  const payload = {
    name,
    file_name: file.originalname || `${name}.${ext}`,
    type: ext,
    description: 'ICTFax Portal Upload',
    quality,
  }
  let doc
  try {
    doc = await apiJson('/documents', { method: 'POST', token, body: payload })
  } catch (err) {
    if (err.status !== 404) throw err
    doc = await apiJson('/messages/documents', { method: 'POST', token, body: payload })
  }
  const documentId =
    typeof doc === 'number' ? doc : doc?.document_id ?? doc?.id ?? null
  if (!documentId) throw new Error('ICTFax lieferte keine document_id zurück.')

  const mediaPaths = [`/documents/${documentId}/media`, `/messages/documents/${documentId}/media`]
  let uploaded = false
  let lastError = null
  for (const mediaPath of mediaPaths) {
    for (const method of ['POST', 'PUT']) {
      try {
        await apiJson(mediaPath, {
          method,
          token,
          body: file.buffer,
          headers: {
          'Content-Type': file.mimetype,
          'Content-Length': String(file.size),
        },
          timeout: 60000,
        })
        uploaded = true
        break
      } catch (err) {
        lastError = err
        if (err.status === 404 || err.status === 405) continue
        throw err
      }
    }
    if (uploaded) break
  }
  if (!uploaded) {
    throw lastError || new Error('Dokument-Upload fehlgeschlagen.')
  }
  return { documentId, ext, name }
}

export function createApp() {
  const app = express()
  app.disable('x-powered-by')
  app.set('trust proxy', 1)
  app.use(express.json({ limit: '1mb' }))
  app.use(cookieParser(SECRET))

  app.use((req, res, next) => {
    if (!LOG_REQUESTS) return next()
    const started = Date.now()
    res.on('finish', () => {
      console.log(
        `[portal] ${req.method} ${req.path} -> ${res.statusCode} ${Date.now() - started}ms`,
      )
    })
    next()
  })

  app.get('/api/health', async (_req, res) => {
    try {
      const r = await fetch(`${API_BASE}/statistics`, {
        signal: AbortSignal.timeout(8000),
      })
      const reachable = r.status === 200 || r.status === 401 || r.status === 403
      if (!reachable) {
        return res.status(503).json({ status: 'degraded', ictfax: 'unexpected', code: r.status })
      }
      return res.json({ status: 'ok', ictfax: 'up' })
    } catch (err) {
      return res.status(503).json({ status: 'degraded', ictfax: 'down', error: err.message })
    }
  })

  app.post('/api/session/login', async (req, res) => {
    const { username, password } = req.body || {}
    if (typeof username !== 'string' || typeof password !== 'string' || !username || !password) {
      return res.status(400).json({ error: 'Benutzername und Passwort erforderlich.' })
    }
    try {
      const data = await apiJson('/authenticate', {
        method: 'POST',
        body: { username, password },
        timeout: 15000,
      })
      const token = data?.token || data?.access_token
      if (!token) return res.status(401).json({ error: 'Login fehlgeschlagen.' })
      const user = profileFromUser(data, username)
      res.cookie('ictfax_token', token, COOKIE_OPTS)
      res.cookie('ictfax_profile', JSON.stringify(user), COOKIE_OPTS)
      return res.json({
        ok: true,
        user,
        ictfaxUrl: process.env.ICTFAX_PUBLIC_URL || null,
      })
    } catch (err) {
      const status = err.status === 401 ? 401 : 502
      return res.status(status).json({ error: safeMessage(err.upstream, 'Login fehlgeschlagen.') })
    }
  })

  app.post('/api/session/logout', (req, res) => {
    clearSessionCookies(res)
    res.json({ ok: true })
  })

  app.get('/api/session', async (req, res) => {
    const token = readToken(req)
    if (!token) return res.json({ authenticated: false })
    const valid = await verifyToken(token)
    if (valid === false) {
      clearSessionCookies(res)
      return res.json({ authenticated: false })
    }
    const stored = readProfile(req)
    const claims = decodeJwtPayload(token)
    const user = stored || {
      username: claims?.username || null,
      user_id: claims?.user_id ?? null,
      is_admin: claims?.is_admin ?? null,
    }
    return res.json({
      authenticated: true,
      user,
      ictfaxUrl: process.env.ICTFAX_PUBLIC_URL || null,
    })
  })

  app.get('/api/setup', requireAuth, async (req, res) => {
    const token = req.ictfaxToken
    const [health, accounts, providers, stats] = await Promise.allSettled([
      apiFetch('/statistics', { token, timeout: 8000 }),
      apiJson('/accounts', { token }),
      apiJson('/providers', { token }),
      apiJson('/statistics', { token }),
    ])
    const pick = (r, fallback) => (r.status === 'fulfilled' ? r.value : fallback)

    const accountList = asList(pick(accounts, []))
    const providerList = asList(pick(providers, []))
    const stat = pick(stats, {})
    const cid = accountList.filter((a) => (a.type || a.account_type) === 'cid')
    const did = accountList.filter((a) => (a.type || a.account_type) === 'did')
    const backendOk =
      health.status === 'fulfilled' && health.value.res && health.value.res.status < 500

    const warnings = [accounts, providers, stats]
      .filter((r) => r.status === 'rejected')
      .map((r) => r.reason?.message || 'Upstream-Fehler')

    res.json({
      health: {
        status: backendOk ? 'ok' : 'down',
        code: health.status === 'fulfilled' ? health.value.res?.status : null,
      },
      accounts: {
        total: accountList.length,
        cid: cid.length,
        did: did.length,
        items: accountList.slice(0, 50),
      },
      providers: { total: providerList.length, items: providerList.slice(0, 50) },
      stats: {
        users: stat.user_total ?? 0,
        transmissions_inbound: stat.transmission_inbound ?? 0,
        transmissions_outbound: stat.transmission_outbound ?? 0,
      },
      checks: {
        backend: backendOk,
        caller_id: cid.length > 0,
        did: did.length > 0,
        sip: providerList.length > 0,
      },
      warnings,
      nativeUrl: process.env.ICTFAX_PUBLIC_URL || null,
    })
  })

  app.get('/api/dashboard', requireAuth, async (req, res) => {
    const token = req.ictfaxToken
    const [stats, outbound, inbound, accounts] = await Promise.allSettled([
      apiJson('/statistics', { token }),
      apiJson('/transmissions?service_flag=2&direction=outbound', { token }),
      apiJson('/transmissions?service_flag=2&direction=inbound', { token }),
      apiJson('/accounts', { token }),
    ])
    const pick = (r, fallback) => (r.status === 'fulfilled' ? r.value : fallback)
    res.json({
      stats: pick(stats, {}),
      outbound: asList(pick(outbound, [])).slice(0, 8),
      inbound: asList(pick(inbound, [])).slice(0, 8),
      accounts: asList(pick(accounts, [])),
      warnings: [stats, outbound, inbound, accounts]
        .filter((r) => r.status === 'rejected')
        .map((r) => r.reason?.message || 'Upstream-Fehler'),
    })
  })

  app.get('/api/accounts', requireAuth, async (req, res, next) => {
    try {
      res.json(asList(await apiJson('/accounts', { token: req.ictfaxToken })))
    } catch (err) {
      next(err)
    }
  })

  app.get('/api/transmissions', requireAuth, async (req, res, next) => {
    const direction = req.query.direction === 'inbound' ? 'inbound' : 'outbound'
    const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 200)
    try {
      const data = await apiJson(
        `/transmissions?service_flag=2&direction=${direction}`,
        { token: req.ictfaxToken },
      )
      res.json(asList(data).slice(0, limit))
    } catch (err) {
      next(err)
    }
  })

  const upload = multer({
    storage: multer.memoryStorage(),
    limits: { fileSize: 20 * 1024 * 1024, files: 1 },
  })

  app.post('/api/fax/send', requireAuth, upload.single('file'), async (req, res, next) => {
    const token = req.ictfaxToken
    const fields = req.body || {}
    try {
      if (!req.file) return res.status(400).json({ error: 'Datei fehlt.' })
      const phone = normalizePhone(fields.phone)
      if (!phone) return res.status(400).json({ error: 'Ungültige Faxnummer.' })
      const accountId = Number(fields.account_id)
      if (!Number.isInteger(accountId) || accountId <= 0) {
        return res.status(400).json({ error: 'Absender-Konto (Caller-ID) fehlt.' })
      }
      const { documentId, name } = await createDocument(token, req.file, fields)

      const program = await apiJson('/programs/sendfax', {
        method: 'POST',
        token,
        body: { document_id: documentId, name },
      })
      const programId =
        typeof program === 'number' ? program : program?.program_id ?? program?.id
      if (!programId) throw new Error('ICTFax lieferte keine program_id zurück.')

      const transmission = await apiJson('/transmissions', {
        method: 'POST',
        token,
        body: {
          program_id: programId,
          title: (fields.title || name).toString().slice(0, 120),
          service_flag: 2,
          account_id: accountId,
          phone,
          email: fields.email || undefined,
          direction: 'outbound',
          origin: 'web',
          try_allowed: 1,
        },
      })
      const transmissionId =
        typeof transmission === 'number'
          ? transmission
          : transmission?.transmission_id ?? transmission?.id ?? transmission?.text_id
      if (!transmissionId) throw new Error('ICTFax lieferte keine transmission_id zurück.')

      const sent = await apiJson(`/transmissions/${transmissionId}/send`, {
        method: 'POST',
        token,
        body: {},
      })
      return res.json({
        ok: true,
        transmission_id: transmissionId,
        spool_id: sent?.spool_id ?? sent?.id ?? null,
      })
    } catch (err) {
      next(err)
    }
  })

  app.get('/api/transmissions/:id/document', requireAuth, async (req, res, next) => {
    const token = req.ictfaxToken
    const id = Number(req.params.id)
    if (!Number.isInteger(id) || id <= 0) {
      return res.status(400).json({ error: 'Ungültige transmission_id.' })
    }
    try {
      let results
      try {
        results = await apiJson(`/transmissions/${id}/results?name=document`, { token })
      } catch (err) {
        if (err.status !== 404) throw err
        results = await apiJson(`/transmissions/${id}/result?name=document`, { token })
      }
      const documentId = Array.isArray(results)
        ? results[0]?.data ?? results[0]?.document_id
        : results?.data ?? results?.document_id
      if (!documentId) return res.status(404).json({ error: 'Kein Dokument vorhanden.' })

      let upstream
      try {
        upstream = await fetch(`${API_BASE}/documents/${documentId}/media`, {
          headers: { Authorization: `Bearer ${token}` },
          signal: AbortSignal.timeout(30000),
        })
        if (upstream.status === 404) {
          upstream = await fetch(`${API_BASE}/messages/documents/${documentId}/media`, {
            headers: { Authorization: `Bearer ${token}` },
            signal: AbortSignal.timeout(30000),
          })
        }
      } catch (err) {
        throw new Error(`Dokument-Download fehlgeschlagen: ${err.message}`)
      }
      if (!upstream.ok) {
        return res.status(upstream.status).json({ error: 'Dokument-Download fehlgeschlagen.' })
      }
      const contentType = upstream.headers.get('content-type') || 'application/pdf'
      const ext = MIME_TO_EXT[contentType] || 'pdf'
      const buf = Buffer.from(await upstream.arrayBuffer())
      res.setHeader('Content-Type', contentType)
      res.setHeader('Content-Disposition', `attachment; filename="fax-${id}.${ext}"`)
      res.setHeader('Cache-Control', 'private, no-store')
      return res.send(buf)
    } catch (err) {
      next(err)
    }
  })

  app.use(express.static(DIST_DIR, { index: false, maxAge: '1h' }))
  app.get('*', (req, res, next) => {
    if (req.path.startsWith('/api/')) return next()
    if (!fs.existsSync(path.join(DIST_DIR, 'index.html'))) {
      return res.status(503).send('Portal-Build fehlt. Bitte Installer erneut ausführen.')
    }
    return res.sendFile(path.join(DIST_DIR, 'index.html'))
  })

  app.use((req, res) => {
    res.status(404).json({ error: 'Nicht gefunden' })
  })

  // eslint-disable-next-line no-unused-vars
  app.use((err, _req, res, _next) => {
    const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 502
    if (status >= 500) console.error('[portal] upstream error:', err.message)
    res.status(status).json({ error: err.message || 'Interner Fehler' })
  })

  return app
}

const isDirectRun =
  process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href

if (isDirectRun) {
  const app = createApp()
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[portal] listening on 0.0.0.0:${PORT}`)
    console.log(`[portal] config: ${configFile || 'environment'}`)
    console.log(`[portal] upstream: ${API_BASE}`)
  })
}
