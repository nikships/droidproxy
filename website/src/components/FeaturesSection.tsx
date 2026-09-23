import Eyebrow from './Eyebrow'
import { noOrphan } from '../typography'

const rowA = [
  {
    tag: 'Auth',
    title: 'Sign in from Settings',
    body: 'Claude, ChatGPT, Antigravity, Copilot, Grok, Kimi, and Muse sign in from Settings. Junie takes a JetBrains API key. Multiple accounts per lab, per-account disable, and automatic token refresh on every session.',
  },
  {
    tag: 'Quota',
    title: 'Live usage windows',
    body: 'Claude shows 5-hour and weekly windows. Codex shows the 5-hour, weekly, or monthly window the plan reports. SuperGrok shows its pooled weekly credits. Refresh on demand — no extra CLI to install.',
  },
  {
    tag: 'Routing',
    title: 'Sequential failover',
    body: 'Stack several accounts on one provider. DroidProxy can stay on one seat until quota runs out, then move mid-request without an error reaching Droid CLI.',
  },
]

const rowB = [
  {
    tag: 'Images',
    title: 'Grok Imagine & GPT Image',
    body: 'Same localhost proxy, no API keys. Bundled skills post to /v1/images/generations using Grok OAuth or ChatGPT Plus/Pro via Codex.',
  },
  {
    tag: 'Copilot',
    title: 'Local Copilot gateway',
    body: 'Device-code login, then pick up to three models your Copilot subscription actually has. Only those three land in Factory’s picker.',
  },
]

function Card({ tag, title, body }: { tag: string; title: string; body: string }) {
  return (
    <article className="feature">
      <span className="usecase-tag">{tag}</span>
      <h3>{title}</h3>
      <p>{noOrphan(body)}</p>
    </article>
  )
}

export default function FeaturesSection() {
  return (
    <section id="features">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="05">Also in the menu bar</Eyebrow>
            <h2>More than a port forward.</h2>
          </div>
          <p>{noOrphan('Auth, quota, failover, image gen, and the Copilot gateway all live in the same menu-bar app that sits next to Wi-Fi.')}</p>
        </div>
        <div className="feature-stack">
          <div className="feature-row feature-row-3">
            {rowA.map((f) => <Card key={f.title} {...f} />)}
          </div>
          <div className="feature-row feature-row-2">
            {rowB.map((f) => <Card key={f.title} {...f} />)}
          </div>
        </div>
      </div>
    </section>
  )
}
