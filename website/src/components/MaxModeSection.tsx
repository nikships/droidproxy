export default function MaxModeSection() {
  return (
    <section id="max-mode" style={{ background: 'var(--bg-alt)' }}>
      <div className="container spotlight">
        <div>
          <span className="spot-pill">⚡ Max Budget Mode</span>
          <h2>One switch, smarter Sonnet.</h2>
          <p>Got a hard problem? Flip Max Budget Mode and Sonnet thinks as long as it wants before answering. It costs more of your subscription quota, but you get better answers on the things that actually matter.</p>
          <dl className="spot-list">
            <dt>What it does</dt>
            <dd>Sonnet 4.6 thinks at full strength on every request</dd>
            <dt>When to use</dt>
            <dd>Tough debugging, big refactors, deep architecture questions</dd>
            <dt>Trade-off</dt>
            <dd>Burns subscription quota faster — but it's still your subscription, not metered Factory tokens</dd>
            <dt>Opus 4.8</dt>
            <dd>Already runs adaptive thinking by default — no toggle needed</dd>
          </dl>
        </div>
        <div className="spot-shot">
          <img
            src="/assets/max-mode.png"
            alt="MAX BUDGET MODE toggle in DroidProxy — Sonnet 4.6 thinking effort active, burning through quota indicator."
            loading="lazy"
          />
        </div>
      </div>
    </section>
  )
}
