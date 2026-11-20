import { useEffect, useState } from 'react'
import { api, formatDate, statusClass, statusLabel } from '../api'

function StatCard({ label, value, tone }) {
  return (
    <div className={`stat ${tone || ''}`}>
      <span className="stat-value">{value ?? 0}</span>
      <span className="stat-label">{label}</span>
    </div>
  )
}

function MiniTable({ rows, empty }) {
  if (!rows || rows.length === 0) return <p className="empty">{empty}</p>
  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>#</th>
            <th>Nummer</th>
            <th>Status</th>
            <th>Zeit</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.transmission_id || row.id}>
              <td>{row.transmission_id || row.id || '–'}</td>
              <td>{row.phone || row.contact_phone || row.fax_to || '–'}</td>
              <td>
                <span className={`badge ${statusClass(row.status)}`}>
                  {statusLabel(row.status)}
                </span>
              </td>
              <td>{formatDate(row.last_run || row.created_at || row.updated_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export default function Dashboard({ onNavigate }) {
  const [data, setData] = useState(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let alive = true
    api('/api/dashboard')
      .then((d) => alive && setData(d))
      .catch((err) => alive && setError(err.message))
      .finally(() => alive && setLoading(false))
    return () => {
      alive = false
    }
  }, [])

  if (loading) return <div className="center">Lade Übersicht …</div>
  if (error) return <div className="panel error-panel">{error}</div>

  const stats = data?.stats || {}
  const outbound = data?.outbound || []
  const inbound = data?.inbound || []

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>Übersicht</h1>
          <p>Status des Faxservers und die letzten Übertragungen.</p>
        </div>
        <button type="button" className="primary" onClick={() => onNavigate('send')}>
          Fax senden
        </button>
      </div>

      {data?.warnings?.length ? (
        <div className="panel warn-panel">
          {data.warnings.map((w, i) => (
            <p key={i}>{w}</p>
          ))}
        </div>
      ) : null}

      <section className="stats">
        <StatCard label="Postausgang" value={stats.transmission_outbound} tone="blue" />
        <StatCard label="Posteingang" value={stats.transmission_inbound} tone="green" />
        <StatCard label="Benutzer" value={stats.user_total} />
        <StatCard label="DIDs" value={stats.did_total} />
      </section>

      <section className="grid-2">
        <div className="panel">
          <div className="panel-head">
            <h2>Letzte ausgehende Faxe</h2>
            <button type="button" className="link" onClick={() => onNavigate('outbox')}>
              alle anzeigen
            </button>
          </div>
          <MiniTable rows={outbound} empty="Noch keine ausgehenden Faxe." />
        </div>

        <div className="panel">
          <div className="panel-head">
            <h2>Letzte eingehende Faxe</h2>
            <button type="button" className="link" onClick={() => onNavigate('inbox')}>
              alle anzeigen
            </button>
          </div>
          <MiniTable rows={inbound} empty="Noch keine eingehenden Faxe." />
        </div>
      </section>
    </div>
  )
}
