import Eyebrow from './Eyebrow'

const faqs = [
  {
    q: 'Does this replace Factory Droid?',
    a: 'No. DroidProxy is a local adapter. You still run the Factory Droid CLI. DroidProxy only changes who gets billed for the model behind /model.',
  },
  {
    q: 'Do I need API keys?',
    a: 'No. Sign in with the same OAuth flows the official apps use. Tokens stay on your Mac under ~/.cli-proxy-api (Copilot and Muse use their own local stores).',
  },
  {
    q: 'Who picks reasoning effort?',
    a: 'Droid CLI. Each DroidProxy model is registered with its native levels so the per-session selector exposes every option the lab supports. The proxy does not inject thinking fields.',
  },
  {
    q: 'What happened to older model names?',
    a: 'The catalog ships the current flagship of each family — Fable 5.1, Opus 5, Sonnet 5, GPT 6 Astra, Gemini 3.8 Flash, Kimi K3. Re-applying Factory models prunes sunset ids from ~/.factory/settings.json.',
  },
  {
    q: 'Is traffic leaving my machine encrypted?',
    a: 'Yes, to the lab. The local hop is http://127.0.0.1:8317. Upstream connections use each provider’s TLS API. The Copilot gateway also binds localhost only.',
  },
  {
    q: 'Windows?',
    a: 'Not yet. Current releases are Apple Silicon macOS 13+. The app is signed, notarized, and auto-updates via Sparkle.',
  },
]

export default function FaqSection() {
  return (
    <section id="faq">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="08">FAQ</Eyebrow>
            <h2>Quick answers.</h2>
          </div>
          <p>The short version of how DroidProxy sits next to Factory without becoming Factory.</p>
        </div>
        <div className="faq">
          {faqs.map((item) => (
            <details key={item.q} className="faq-item">
              <summary>{item.q}</summary>
              <p>{item.a}</p>
            </details>
          ))}
        </div>
      </div>
    </section>
  )
}
