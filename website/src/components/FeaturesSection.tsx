import Eyebrow from './Eyebrow'

const features = [
  {
    tag: 'Auth',
    title: 'One-click OAuth',
    body: 'Claude, ChatGPT, Gemini, Copilot, Grok, Kimi, Muse, and Junie login from Settings. Multiple accounts per lab, per-account disable, and automatic token refresh.',
  },
  {
    tag: 'Quota',
    title: 'Live usage windows',
    body: 'Claude and Codex 5-hour and weekly OAuth windows render in Settings. Refresh on demand. No extra CLI to install.',
  },
  {
    tag: 'Routing',
    title: 'Sequential failover',
    body: 'Stack several accounts on one provider. DroidProxy can stay on one seat until quota runs out, then move mid-request without an error reaching Droid.',
  },
  {
    tag: 'Images',
    title: 'Grok Imagine & GPT Image',
    body: 'Same localhost proxy, no API keys. Bundled skills post to /v1/images/generations using Grok OAuth or ChatGPT Plus/Pro via Codex.',
  },
  {
    tag: 'Copilot',
    title: 'Local Copilot gateway',
    body: 'Device-code login, then pick up to three models your Copilot subscription actually has. Only those three land in Factory.',
  },
]

export default function FeaturesSection() {
  return (
    <section id="features">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="05">Also in the menu bar</Eyebrow>
            <h2>More than a port forward.</h2>
          </div>
          <p>Auth, quota, failover, image gen, and the Copilot gateway all live in the same app that sits next to Wi-Fi.</p>
        </div>
        <div className="feature-grid">
          {features.map((f) => (
            <article className="feature" key={f.title}>
              <span className="usecase-tag">{f.tag}</span>
              <h3>{f.title}</h3>
              <p>{f.body}</p>
            </article>
          ))}
        </div>
      </div>
    </section>
  )
}
