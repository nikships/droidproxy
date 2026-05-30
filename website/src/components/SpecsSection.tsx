const specs = [
  { label: 'Platform', value: 'macOS 13.0+', small: 'Ventura · Sonoma · Sequoia' },
  { label: 'Architecture', value: 'Apple Silicon', small: 'M1 · M2 · M3 · M4' },
  { label: 'Local ports', value: '8317', small: ':8317/v1 · :8318 child', mono: true },
  { label: 'License', value: 'MIT', small: 'open source · free forever' },
  { label: 'Auto-update', value: 'Sparkle', small: 'EdDSA-signed appcast' },
  { label: 'Auth model', value: 'Native OAuth', small: 'no API keys to provision' },
  { label: 'Built on', value: 'CLIProxyAPI', small: 'router-for-me · MIT' },
  { label: 'Distribution', value: 'Notarized .zip', small: 'Sparkle auto-updates' },
  { label: 'Usage tracking', value: 'Built-in', small: 'Claude · Codex · 5h + weekly' },
]

export default function SpecsSection() {
  return (
    <section id="specs">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 05 — Spec sheet</div>
            <h2 style={{ marginTop: 10 }}>The boring numbers.</h2>
          </div>
          <p>Everything worth knowing about runtime, footprint, and licensing — at a glance, no marketing detour.</p>
        </div>

        <div className="specs">
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
