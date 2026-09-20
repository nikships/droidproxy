import { GITHUB, RELEASES } from '../content'

export default function ClosingCTA() {
  return (
    <section className="closing">
      <div className="container">
        <h2>Use Factory Droid on the subscriptions you already have.</h2>
        <p>Fable 5.1, GPT 6 Astra, Gemini 3.8 Flash, Grok 4.6 — billed by the lab, not a second token pack. Free, open source, signed by Apple.</p>
        <div className="closing-cta">
          <a href={RELEASES} className="btn btn-primary btn-lg" target="_blank" rel="noopener">
            Download for macOS →
          </a>
          <a href={GITHUB} className="btn btn-ghost btn-lg" target="_blank" rel="noopener">
            Read the source
          </a>
        </div>
      </div>
    </section>
  )
}
