import { useEffect, useState } from 'react'
import { api } from './api'
import Login from './pages/Login.jsx'
import Dashboard from './pages/Dashboard.jsx'
import SendFax from './pages/SendFax.jsx'
import Transmissions from './pages/Transmissions.jsx'
import Setup from './pages/Setup.jsx'

const TABS = [
  { id: 'dashboard', label: 'Übersicht' },
  { id: 'send', label: 'Fax senden' },
  { id: 'outbox', label: 'Postausgang' },
  { id: 'inbox', label: 'Posteingang' },
  { id: 'setup', label: 'Einrichtung' },
]

export default function App() {
  const [session, setSession] = useState(null)
  const [tab, setTab] = useState('dashboard')
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    api('/api/session')
      .then(setSession)
      .catch(() => setSession({ authenticated: false }))
      .finally(() => setLoading(false))
  }, [])

  async function logout() {
    try {
      await api('/api/session/logout', { method: 'POST' })
    } finally {
      setSession({ authenticated: false })
    }
  }

  if (loading) return <div className="center">Lade Portal …</div>
  if (!session?.authenticated) {
    return <Login onLogin={setSession} />
  }

  const username =
    session.user?.username || session.user?.email || session.user?.name || 'angemeldet'

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">FX</span>
          <div>
            <strong>ICTFax Portal</strong>
            <small>Faxen über ICTFax</small>
          </div>
        </div>
        <div className="topbar-right">
          <span className="user">{username}</span>
          <button type="button" className="ghost" onClick={logout}>
            Abmelden
          </button>
        </div>
      </header>

      <nav className="tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            className={tab === t.id ? 'tab active' : 'tab'}
            onClick={() => setTab(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {tab === 'dashboard' && <Dashboard onNavigate={setTab} />}
        {tab === 'send' && <SendFax />}
        {tab === 'outbox' && <Transmissions direction="outbound" />}
        {tab === 'inbox' && <Transmissions direction="inbound" />}
        {tab === 'setup' && <Setup />}
      </main>

      <footer className="footer">
        ICTFax Portal
        {session.ictfaxUrl ? (
          <>
            {' · '}
            <a href={session.ictfaxUrl} target="_blank" rel="noreferrer">
              Native Admin-UI
            </a>
          </>
        ) : null}
      </footer>
    </div>
  )
}
