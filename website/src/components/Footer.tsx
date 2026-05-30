export default function Footer() {
  return (
    <footer className="foot">
      <div className="container foot-inner">
        <a href="#" className="brand">
          <img src="/assets/logo.png" alt="" />
          <span>DroidProxy</span>
          <small>v1.8.32 · MIT</small>
        </a>
        <div className="foot-links">
          <a href="https://github.com/anand-92/droidproxy" target="_blank" rel="noopener">GitHub</a>
          <a href="https://github.com/anand-92/droidproxy/releases" target="_blank" rel="noopener">Releases</a>
          <a href="https://github.com/anand-92/droidproxy/issues" target="_blank" rel="noopener">Issues</a>
          <a href="https://github.com/anand-92/droidproxy/blob/main/LICENSE" target="_blank" rel="noopener">License</a>
          <a href="https://github.com/router-for-me/CLIProxyAPI" target="_blank" rel="noopener">CLIProxyAPI</a>
        </div>
      </div>
    </footer>
  )
}
