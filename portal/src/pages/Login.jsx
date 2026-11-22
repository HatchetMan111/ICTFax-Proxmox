import { useState } from 'react'
import { api } from '../api'

export default function Login({ onLogin }) {
  const [username, setUsername] = useState('admin@ictcore.org')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)

  async function submit(event) {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      const data = await api('/api/session/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password }),
      })
      onLogin({
        authenticated: true,
        user: data.user,
        ictfaxUrl: data.ictfaxUrl,
      })
    } catch (err) {
      setError(err.message || 'Login fehlgeschlagen.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card" onSubmit={submit}>
        <div className="brand login-brand">
          <span className="brand-mark">FX</span>
          <div>
            <strong>ICTFax Portal</strong>
            <small>Anmeldung am Faxserver</small>
          </div>
        </div>

        <label>
          Benutzername
          <input
            type="text"
            autoComplete="username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            required
          />
        </label>

        <label>
          Passwort
          <input
            type="password"
            autoComplete="current-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            autoFocus
          />
        </label>

        {error ? <p className="error">{error}</p> : null}

        <button type="submit" className="primary" disabled={busy}>
          {busy ? 'Anmelden …' : 'Anmelden'}
        </button>

        <p className="hint">
          Erstlogin: <code>admin</code> oder <code>admin@ictcore.org</code> /{' '}<code>helloAdmin</code> – bitte sofort ändern.
        </p>
      </form>
    </div>
  )
}
