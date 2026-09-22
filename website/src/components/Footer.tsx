import { GITHUB, ISSUES, LICENSE, CLIPROXY, VERSION } from '../content'

export default function Footer() {
  return (
    <footer className="foot">
      <div className="container foot-inner">
        <a href="#" className="brand">
          <img src="/assets/logo.png" alt="" />
          <span>DroidProxy</span>
          <small>v{VERSION} · MIT</small>
        </a>
        <div className="foot-links">
          <a href={GITHUB} target="_blank" rel="noopener">GitHub</a>
          <a href={`${GITHUB}/releases`} target="_blank" rel="noopener">Releases</a>
          <a href={ISSUES} target="_blank" rel="noopener">Issues</a>
          <a href={LICENSE} target="_blank" rel="noopener">License</a>
          <a href={CLIPROXY} target="_blank" rel="noopener">CLIProxyAPI</a>
        </div>
      </div>
    </footer>
  )
}
