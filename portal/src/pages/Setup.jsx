import { useEffect, useState } from 'react'
import { api, formatDate } from '../api'

function CheckRow({ ok, label, hint }) {
  return (
    <div className={`check-row ${ok ? 'ok' : 'todo'}`}>
      <span className="check-dot" aria-hidden="true">
        {ok ? '✓' : '!'}
      </span>
      <div className="check-text">
        <strong>{label}</strong>
        {hint ? <small>{hint}</small> : null}
      </div>
    </div>
  )
}

export default function Setup() {
  const [data, setData] = useState(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let alive = true
    api('/api/setup')
      .then((d) => alive && setData(d))
      .catch((err) => alive && setError(err.message))
      .finally(() => alive && setLoading(false))
    return () => {
      alive = false
    }
  }, [])

  if (loading) return <div className="center">Lade Einrichtung …</div>

  const checks = data?.checks || {}
  const accounts = data?.accounts || {}
  const providers = data?.providers || {}
  const nativeUrl = data?.nativeUrl

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>Einrichtung</h1>
          <p>
            Prüfe, ob der Faxserver betriebsbereit ist. SIP-Trunk, Rufnummern und
            E-Mail→Fax werden im ICTFax-Admin eingerichtet.
          </p>
        </div>
        {nativeUrl ? (
          <a className="primary" href={nativeUrl} target="_blank" rel="noreferrer">
            ICTFax-Admin öffnen
          </a>
        ) : null}
      </div>

      {error ? <div className="panel error-panel">{error}</div> : null}

      {data?.warnings?.length ? (
        <div className="panel warn-panel">
          {data.warnings.map((w, i) => (
            <p key={i}>{w}</p>
          ))}
        </div>
      ) : null}

      <section className="stats">
        <div className="stat">
          <span className="stat-value">{data?.stats?.users ?? 0}</span>
          <span className="stat-label">Benutzer</span>
        </div>
        <div className="stat">
          <span className="stat-value">{accounts.total ?? 0}</span>
          <span className="stat-label">Konten</span>
        </div>
        <div className="stat">
          <span className="stat-value">{accounts.did ?? 0}</span>
          <span className="stat-label">DIDs</span>
        </div>
        <div className="stat">
          <span className="stat-value">{providers.total ?? 0}</span>
          <span className="stat-label">SIP-Trunks</span>
        </div>
      </section>

      <section className="grid-2">
        <div className="panel">
          <div className="panel-head">
            <h2>Bereitschaft</h2>
            <span className={`badge ${checks.backend ? 'ok' : 'bad'}`}>
              {checks.backend ? 'Backend erreichbar' : 'Backend nicht erreichbar'}
            </span>
          </div>

          <CheckRow
            ok={checks.backend}
            label="ICTFax-Backend"
            hint={
              checks.backend
                ? 'Portal und REST-API antworten.'
                : 'Container prüfen: journalctl -u ictfax -n 50'
            }
          />
          <CheckRow
            ok={checks.caller_id}
            label="Absender-Konto (Caller-ID)"
            hint={
              checks.caller_id
                ? `${accounts.cid} Konto/Konten für den Versand vorhanden.`
                : 'Im ICTFax-Admin unter Konten (CID) anlegen.'
            }
          />
          <CheckRow
            ok={checks.sip}
            label="SIP-Trunk / Provider"
            hint={
              checks.sip
                ? `${providers.total} Provider konfiguriert.`
                : 'Im ICTFax-Admin unter Provider (SIP) den Trunk eintragen.'
            }
          />
          <CheckRow
            ok={checks.did}
            label="Eingehende Rufnummern (DID)"
            hint={
              checks.did
                ? `${accounts.did} DID(s) vorhanden.`
                : 'Für Empfang: DID anlegen und einer eingehenden Regel zuordnen.'
            }
          />
          <CheckRow
            ok
            label="E-Mail→Fax"
            hint="MX der Domain auf diesen Server zeigen lassen, Port 25 muss erreichbar sein."
          />
        </div>

        <div className="panel">
          <div className="panel-head">
            <h2>Konten</h2>
            <span className="badge muted">{accounts.total ?? 0}</span>
          </div>
          {accounts.items && accounts.items.length > 0 ? (
            <div className="table-wrap">
              <table>
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Name</th>
                    <th>Nummer</th>
                    <th>Typ</th>
                  </tr>
                </thead>
                <tbody>
                  {accounts.items.map((acc, i) => (
                    <tr key={acc.account_id ?? acc.id ?? i}>
                      <td>{acc.account_id ?? acc.id ?? '–'}</td>
                      <td>{acc.name || acc.description || '–'}</td>
                      <td>{acc.phone || '–'}</td>
                      <td>{acc.type || acc.account_type || '–'}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="empty">Noch keine Konten angelegt.</p>
          )}
        </div>
      </section>

      <section className="panel">
        <div className="panel-head">
          <h2>Zusammenfassung</h2>
        </div>
        <p className="hint">
          Ausgehend: {data?.stats?.transmissions_outbound ?? 0} · Eingehend:{' '}
          {data?.stats?.transmissions_inbound ?? 0}
        </p>
        <p className="hint">
          Stand: {formatDate(Date.now())} · Änderungen im ICTFax-Admin werden hier
          nach einem Neuladen sichtbar.
        </p>
      </section>

      <section className="panel note">
        <h3>Was gehört in den ICTFax-Admin?</h3>
        <p>
          <strong>Provider (SIP-Trunk):</strong> Zugangsdaten des Anbieters, Codec
          T.38 oder G.711. Ohne Trunk kann kein Fax raus.
        </p>
        <p>
          <strong>Konten (CID):</strong> Rufnummer, die als Absender verwendet wird.
          Für den Versand muss mindestens ein Konto vom Typ CID existieren.
        </p>
        <p>
          <strong>DID:</strong> Eingehende Rufnummer plus Regel „Fax → E-Mail“ oder
          „Fax → Dokument“.
        </p>
        <p>
          <strong>E-Mail→Fax:</strong> MX-Record auf den Server, Port 25 offen.
          Absender-Adresse entspricht der zugewiesenen Faxnummer.
        </p>
      </section>
    </div>
  )
}