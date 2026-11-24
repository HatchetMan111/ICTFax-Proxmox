import { useEffect, useRef, useState } from 'react'
import { api } from '../api'

export default function SendFax() {
  const [accounts, setAccounts] = useState([])
  const [accountId, setAccountId] = useState('')
  const [phone, setPhone] = useState('')
  const [title, setTitle] = useState('')
  const [email, setEmail] = useState('')
  const [quality, setQuality] = useState('standard')
  const [file, setFile] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [result, setResult] = useState(null)
  const fileRef = useRef(null)

  useEffect(() => {
    api('/api/accounts')
      .then((list) => {
        const rows = Array.isArray(list) ? list : []
        setAccounts(rows)
        if (rows.length > 0) {
          setAccountId(String(rows[0].account_id ?? rows[0].id ?? ''))
        }
      })
      .catch((err) => setError(err.message))
  }, [])

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')
    setResult(null)
    try {
      if (!file) throw new Error('Bitte eine PDF-/TIFF-Datei auswählen.')
      const form = new FormData()
      form.append('account_id', accountId)
      form.append('phone', phone)
      form.append('title', title || file.name)
      form.append('email', email)
      form.append('quality', quality)
      form.append('file', file)
      const data = await api('/api/fax/send', { method: 'POST', body: form })
      setResult(data)
      setFile(null)
      setTitle('')
      setPhone('')
      setEmail('')
      if (fileRef.current) fileRef.current.value = ''
    } catch (err) {
      setError(err.message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="stack">
      <div className="page-head">
        <div>
          <h1>Fax senden</h1>
          <p>PDF, TIFF, PNG oder JPEG hochladen und an eine Faxnummer senden.</p>
        </div>
      </div>

      <form className="panel form" onSubmit={submit}>
        <div className="form-row">
          <label>
            Absender (Caller-ID)
            <select
              value={accountId}
              onChange={(e) => setAccountId(e.target.value)}
              required
            >
              {accounts.length === 0 ? <option value="">Kein Konto gefunden</option> : null}
              {accounts.map((acc) => {
                const id = acc.account_id ?? acc.id
                return (
                  <option key={id} value={id}>
                    {acc.phone || acc.name || `Konto ${id}`}
                  </option>
                )
              })}
            </select>
          </label>

          <label>
            Faxnummer
            <input
              type="tel"
              placeholder="+493012345678"
              value={phone}
              onChange={(e) => setPhone(e.target.value)}
              required
            />
          </label>
        </div>

        <div className="form-row">
          <label>
            Titel (optional)
            <input
              type="text"
              placeholder="Rechnung 2026-001"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
            />
          </label>

          <label>
            E-Mail (optional, für Status)
            <input
              type="email"
              placeholder="empfaenger@example.org"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
            />
          </label>
        </div>

        <div className="form-row">
          <label>
            Qualität
            <select value={quality} onChange={(e) => setQuality(e.target.value)}>
              <option value="standard">Standard</option>
              <option value="fine">Fine</option>
              <option value="super">Super</option>
              <option value="ultra">Ultra</option>
            </select>
          </label>

          <label>
            Datei
            <input
              ref={fileRef}
              type="file"
              accept="application/pdf,image/tiff,image/png,image/jpeg"
              onChange={(e) => setFile(e.target.files?.[0] || null)}
              required
            />
          </label>
        </div>

        {error ? <p className="error">{error}</p> : null}
        {result ? (
          <p className="success">
            Fax in die Warteschlange gestellt (Transmission #{result.transmission_id}
            {result.spool_id ? `, Spool #${result.spool_id}` : ''}).
          </p>
        ) : null}

        <div className="actions">
          <button type="submit" className="primary" disabled={busy || accounts.length === 0}>
            {busy ? 'Sende …' : 'Fax senden'}
          </button>
        </div>
      </form>

      <div className="panel note">
        <h3>Hinweis</h3>
        <p>
          Der Versand benötigt einen konfigurierten SIP-Trunk oder ein ATA-Gerät im
          ICTFax-Adminbereich. Eingehende Faxe und DID-Zuordnung werden dort ebenfalls
          eingerichtet.
        </p>
      </div>
    </div>
  )
}
