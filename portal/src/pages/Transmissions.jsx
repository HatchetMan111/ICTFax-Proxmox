import { useCallback, useEffect, useState } from 'react'
import { api, formatDate, statusClass, statusLabel } from '../api'

export default function Transmissions({ direction }) {
  const [rows, setRows] = useState([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)

  const load = useCallback(() => {
    setLoading(true)
    setError('')
    api(`/api/transmissions?direction=${direction}&limit=100`)
      .then((data) => setRows(Array.isArray(data) ? data : []))
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false))
  }, [direction])

  useEffect(() => {
    load()
  }, [load])

  const inbound = direction === 'inbound'

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>{inbound ? 'Posteingang' : 'Postausgang'}</h1>
          <p>
            {inbound
              ? 'Empfangene Faxe – Dokumente können heruntergeladen werden.'
              : 'Gesendete und wartende Faxe mit Status.'}
          </p>
        </div>
        <button type="button" className="ghost" onClick={load} disabled={loading}>
          {loading ? 'Lade …' : 'Aktualisieren'}
        </button>
      </div>

      {error ? <div className="panel error-panel">{error}</div> : null}

      <div className="panel">
        {loading ? (
          <p className="empty">Lade Übertragungen …</p>
        ) : rows.length === 0 ? (
          <p className="empty">
            {inbound ? 'Keine eingehenden Faxe.' : 'Keine ausgehenden Faxe.'}
          </p>
        ) : (
          <div className="table-wrap">
            <table>
              <thead>
                <tr>
                  <th>#</th>
                  <th>Nummer</th>
                  <th>Titel</th>
                  <th>Status</th>
                  <th>Zeit</th>
                  <th>Ergebnis</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {rows.map((row) => {
                  const id = row.transmission_id || row.id
                  return (
                    <tr key={id}>
                      <td>{id}</td>
                      <td>{row.phone || row.contact_phone || row.fax_to || '–'}</td>
                      <td className="title-cell">{row.title || row.name || '–'}</td>
                      <td>
                        <span className={`badge ${statusClass(row.status)}`}>
                          {statusLabel(row.status)}
                        </span>
                      </td>
                      <td>{formatDate(row.last_run || row.created_at || row.updated_at)}</td>
                      <td className="result-cell">{row.response || row.result || '–'}</td>
                      <td>
                        <a
                          className="link"
                          href={`/api/transmissions/${id}/document`}
                          target="_blank"
                          rel="noreferrer"
                        >
                          Dokument
                        </a>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
