import { GitHubIcon } from './icons'
import { GITHUB, RELEASES } from '../content'

export default function Navbar() {
  return (
    <header className="nav">
      <div className="container nav-inner">
        <a href="#" className="brand">
          <img src="/assets/logo.png" alt="" />
          <span>DroidProxy</span>
        </a>
        <nav className="nav-links">
          <a href="#why">Why</a>
          <a href="#how-it-works">How</a>
          <a href="#features">Features</a>
          <a href="#models">Models</a>
          <a href="#install">Install</a>
          <a href={GITHUB} target="_blank" rel="noopener">GitHub</a>
        </nav>
        <div className="nav-cta">
          <a
            href={GITHUB}
            target="_blank"
            rel="noopener"
            className="btn btn-ghost"
            aria-label="GitHub"
          >
            <GitHubIcon />
            <span>Star</span>
          </a>
          <a
            href={RELEASES}
            target="_blank"
            rel="noopener"
            className="btn btn-primary"
          >
            Download →
          </a>
        </div>
      </div>
    </header>
  )
}
