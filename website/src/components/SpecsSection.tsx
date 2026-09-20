const specs = [
  { label: 'Platform', value: 'macOS 13.0+', small: 'Ventura through current' },
  { label: 'Architecture', value: 'Apple Silicon', small: 'M1 through M5' },
  { label: 'ThinkingProxy', value: ':8317', small: 'client-facing localhost', mono: true },
  { label: 'CLIProxyAPI', value: ':8318', small: 'bundled child process', mono: true },
  { label: 'Copilot gateway', value: ':8319', small: 'selected models only', mono: true },
  { label: 'Auth', value: 'Native OAuth', small: 'no API keys to provision' },
  { label: 'Auto-update', value: 'Sparkle', small: 'EdDSA-signed appcast' },
  { label: 'Distribution', value: 'Notarized .zip', small: 'signed by Apple' },
  { label: 'Quota', value: 'Built-in', small: 'Claude · Codex · 5h + weekly' },
  { label: 'Built on', value: 'CLIProxyAPI', small: 'router-for-me · MIT' },
  { label: 'License', value: 'MIT', small: 'open source · free forever' },
]

export default function SpecsSection() {
  return (
    <section id="specs">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 06 — Spec sheet</div>
            <h2 style={{ marginTop: 10 }}>The boring numbers.</h2>
          </div>
          <p>Runtime, ports, and licensing — at a glance. All local backends bind to localhost only.</p>
        </div>

        <div className="specs specs-wide">
          {specs.map((s) => (
            <div className="spec" key={s.label}>
              <div className="spec-label">{s.label}</div>
              <div className={`spec-value ${s.mono ? 'mono num' : ''}`}>
                {s.value}
                <small>{s.small}</small>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
