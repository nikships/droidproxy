import { DownloadIcon, GitHubIcon } from './icons'

export default function HeroSection() {
  return (
    <section className="hero" style={{ borderBottom: '1px solid var(--border)' }}>
      <div className="container hero-grid">
        <div>
          <span className="eyebrow"><span className="dot"></span>v1.8.32 · macOS · free & open source</span>
          <h1 className="title">
            Use your <em>Claude, ChatGPT & Gemini</em> subscriptions inside Factory Droid.
          </h1>
          <p className="lede">
            Factory Droid is a great coding agent — but its token packages are pricey because they pay full API rates upstream. DroidProxy is a tiny macOS menu bar app that lets Factory Droid run on the Claude, ChatGPT, and Gemini subscriptions you already pay for. Same Droid, same models, your existing plan.
          </p>
          <div className="hero-cta">
            <a href="https://github.com/anand-92/droidproxy/releases/latest" className="btn btn-primary btn-lg" target="_blank" rel="noopener">
              Download for macOS
              <DownloadIcon />
            </a>
            <a href="https://github.com/anand-92/droidproxy" className="btn btn-ghost btn-lg" target="_blank" rel="noopener">
              <GitHubIcon />
              View on GitHub
            </a>
          </div>
          <div className="hero-meta">
            <span><span className="pip"></span>Free forever</span>
            <span><span className="pip"></span>macOS · Apple Silicon</span>
            <span><span className="pip"></span>Open source</span>
            <span><span className="pip"></span>Signed & notarized by Apple</span>
          </div>
        </div>

        <div className="product-shot-wrap">
          <img
            className="product-shot"
            src="/assets/settings-screenshot.png"
            alt="DroidProxy settings window — Factory custom models applied, Claude, ChatGPT, and Gemini connected."
            loading="eager"
          />
        </div>
      </div>
    </section>
  )
}
