import { DownloadIcon, GitHubIcon } from './icons'
import { VERSION, GITHUB, RELEASES } from '../content'

export default function HeroSection() {
  return (
    <section className="hero">
      <div className="container hero-grid">
        <div className="hero-copy">
          <span className="eyebrow"><span className="dot"></span>v{VERSION} · macOS · free & open source</span>
          <h1 className="title">
            Run Factory Droid on the <em>subscriptions you already pay for</em>.
          </h1>
          <p className="lede">
            DroidProxy is a signed macOS menu bar app that lets Factory Droid talk to Claude, ChatGPT, Gemini, Copilot, Grok, Kimi, Muse, and Junie through the plans you already have. Same Droid CLI. Same agent. No Factory token markup.
          </p>
          <div className="hero-cta">
            <a href={RELEASES} className="btn btn-primary btn-lg" target="_blank" rel="noopener">
              Download for macOS
              <DownloadIcon />
            </a>
            <a href={GITHUB} className="btn btn-ghost btn-lg" target="_blank" rel="noopener">
              <GitHubIcon />
              View on GitHub
            </a>
          </div>
          <div className="hero-meta">
            <span><span className="pip"></span>Free forever</span>
            <span><span className="pip"></span>macOS · Apple Silicon</span>
            <span><span className="pip"></span>Open source · MIT</span>
            <span><span className="pip"></span>Signed & notarized by Apple</span>
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
