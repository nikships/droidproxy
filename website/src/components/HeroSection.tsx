import { VERSION, GITHUB, RELEASES } from '../content'
import { noOrphan } from '../typography'
import Eyebrow from './Eyebrow'

export default function HeroSection() {
  return (
    <section className="hero">
      <div className="container hero-grid">
        <div className="hero-copy">
          <Eyebrow index="00">v{VERSION} · macos · mit</Eyebrow>
          <h1 className="title">
            Use the plans you already pay for.
          </h1>
          <p className="lede">
            {noOrphan('DroidProxy is a signed macOS menu bar app that lets Factory Droid talk to Claude, ChatGPT, Antigravity, Copilot, Grok, Kimi, Muse, and Junie through the plans you already have — same Droid CLI, same agent, no Factory token markup.')}
          </p>
          <div className="hero-cta">
            <a href={RELEASES} className="btn btn-primary btn-lg" target="_blank" rel="noopener">
              Download for macOS →
            </a>
            <a href={GITHUB} className="btn btn-ghost btn-lg" target="_blank" rel="noopener">
              View on GitHub
            </a>
          </div>
          <div className="hero-meta">
            <span>Free forever · MIT</span>
            <span>macOS · Apple Silicon</span>
            <span>Signed & notarized</span>
          </div>
        </div>

        <div className="hero-visual">
          <img
            className="cli-shot"
            src="/assets/droid-cli.png"
            alt="Factory Droid CLI — a New Chat Session with tool calls, a plan, and the prompt composer."
            loading="eager"
          />
          <img
            className="settings-shot"
            src="/assets/settings-screenshot.png"
            alt="DroidProxy Settings — Claude, ChatGPT, and Gemini connected, Factory custom models applied."
            loading="eager"
          />
        </div>
      </div>
    </section>
  )
}
