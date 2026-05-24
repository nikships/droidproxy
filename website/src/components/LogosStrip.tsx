export default function LogosStrip() {
  return (
    <section className="logos" style={{ padding: '28px 0' }}>
      <div className="container logos-inner">
        <span className="logos-label">Bring your own subscription</span>
        <div className="logos-row">
          <span className="logo-chip">
            <img src="/assets/icon-claude.png" alt="" /> Claude
            <small style={{ color: 'var(--dim)', fontFamily: 'var(--font-mono)', fontSize: 11, marginLeft: 4 }}>Anthropic</small>
          </span>
          <span className="logo-chip">
            <img src="/assets/icon-codex.png" alt="" /> ChatGPT
            <small style={{ color: 'var(--dim)', fontFamily: 'var(--font-mono)', fontSize: 11, marginLeft: 4 }}>OpenAI</small>
          </span>
          <span className="logo-chip">
            <img src="/assets/icon-gemini.png" alt="" /> Gemini
            <small style={{ color: 'var(--dim)', fontFamily: 'var(--font-mono)', fontSize: 11, marginLeft: 4 }}>Google</small>
          </span>
          <span className="logo-chip">
            <img src="/assets/icon-cursor.png" alt="" /> Cursor
            <small style={{ color: 'var(--dim)', fontFamily: 'var(--font-mono)', fontSize: 11, marginLeft: 4 }}>StandardAgents</small>
          </span>
          <span className="logo-chip" style={{ opacity: 0.85, marginLeft: 'auto' }}>
            <img src="/assets/factory-logo.svg" alt="" style={{ width: 'auto', height: 14 }} />
            <span style={{ color: 'var(--muted)', fontFamily: 'var(--font-mono)', fontSize: 11 }}>→ runs in Factory Droid</span>
          </span>
        </div>
      </div>
    </section>
  )
}
