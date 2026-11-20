export async function api(path, options = {}) {
  const res = await fetch(path, { credentials: 'same-origin', ...options })
  const type = res.headers.get('content-type') || ''
  const data = type.includes('application/json') ? await res.json() : await res.text()
  if (!res.ok) {
    const message =
      (data && typeof data === 'object' && (data.error || data.message)) ||
      (typeof data === 'string' && data) ||
      `HTTP ${res.status}`
    throw new Error(message)
  }
  return data
}

export function formatDate(value) {
  if (!value) return '–'
  const normalized =
    typeof value === 'number' && value < 1e12 ? value * 1000 : value
  const date = new Date(normalized)
  if (Number.isNaN(date.getTime())) return String(value)
  return date.toLocaleString('de-DE', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

export function statusLabel(status) {
  const s = String(status || '').toLowerCase()
  if (s === 'complete' || s === 'completed' || s === 'sent') return 'Gesendet'
  if (s === 'failed' || s === 'error') return 'Fehlgeschlagen'
  if (s === 'pending' || s === 'queued' || s === 'new') return 'In Warteschlange'
  if (s === 'sending' || s === 'in_progress') return 'Läuft'
  if (s === 'received') return 'Empfangen'
  return status || 'Unbekannt'
}

export function statusClass(status) {
  const s = String(status || '').toLowerCase()
  if (s === 'complete' || s === 'completed' || s === 'sent' || s === 'received') return 'ok'
  if (s === 'failed' || s === 'error') return 'bad'
  if (s === 'pending' || s === 'queued' || s === 'new' || s === 'sending' || s === 'in_progress') return 'warn'
  return 'muted'
}
