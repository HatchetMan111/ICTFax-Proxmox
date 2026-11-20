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
  return data.message || data.error?.message || data.error || fallback
}

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

async function getTokenPayload(token) {
  try {
    const { res, data } = await apiFetch('/token_payload', {
      method: 'POST',
      body: { token },
      timeout: 10000,
    })
    return res.ok ? data : null
  } catch {
    return null
  }
}

function readToken(req) {
  return req.signedCookies?.ictfax_token || null
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
  const quality = ['standard', 'fine', 'superfine'].includes(fields.quality)
    ? fields.quality
    : 'standard'
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
      res.cookie('ictfax_token', token, COOKIE_OPTS)
      const user = await getTokenPayload(token)
      return res.json({
        ok: true,
        user: user || { username },
        ictfaxUrl: process.env.ICTFAX_PUBLIC_URL || null,
      })
    } catch (err) {
      const status = err.status === 401 ? 401 : 502
      return res.status(status).json({ error: safeMessage(err.upstream, 'Login fehlgeschlagen.') })
    }
  })

  app.post('/api/session/logout', (req, res) => {
    res.clearCookie('ictfax_token', { ...COOKIE_OPTS, maxAge: undefined })
    res.json({ ok: true })
  })

  app.get('/api/session', async (req, res) => {
    const token = readToken(req)
    if (!token) return res.json({ authenticated: false })
    const user = await getTokenPayload(token)
    if (!user) {
      res.clearCookie('ictfax_token', { ...COOKIE_OPTS, maxAge: undefined })
      return res.json({ authenticated: false })
    }
    return res.json({
      authenticated: true,
      user,
      ictfaxUrl: process.env.ICTFAX_PUBLIC_URL || null,
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
