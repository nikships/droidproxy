const steps = [
  {
    num: '01',
    name: 'You sign in',
    desc: 'Open Settings from the menu bar and log in with the same browser flow you already use for Claude, ChatGPT, Gemini, Copilot, Grok, Kimi, Muse, Cursor, or Junie. Connect as many or as few as you like.',
    portLabel: 'handled by',
    port: 'DroidProxy',
  },
  {
    num: '02',
    name: 'Tokens stay on your Mac',
    desc: 'OAuth credentials never leave localhost. DroidProxy refreshes them in the background so sessions do not die mid-run. Settings also shows live Claude and Codex quota windows — 5-hour and weekly — so you can see what is left before the next reset.',
    portLabel: 'stored at',
    port: '~/.cli-proxy-api',
  },
  {
    num: '03',
    name: 'Droid uses your plan',
    desc: 'Click Apply Factory Models once. Droid CLI grows a DroidProxy: … entry for every connected lab. Pick one with /model and every request hits localhost:8317, then the lab that actually bills you.',
    portLabel: 'billed by',
    port: 'your AI lab',
  },
]

export default function HowItWorksSection() {
  return (
    <section id="how-it-works">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 02 — How it works</div>
            <h2 style={{ marginTop: 10 }}>Sign in once. Factory Droid uses it.</h2>
          </div>
          <p>DroidProxy lives in the menu bar. You authenticate through it, it writes custom models into Factory, and Droid keeps the same keyboard-first workflow — slash commands, skills, missions, diffs — on your subscription.</p>
        </div>

        <div className="flow">
          {steps.map((s) => (
            <div className="flow-row" key={s.num}>
              <div className="flow-stage">
                <span className="flow-num">{s.num}</span>
                <span className="flow-stage-name">{s.name}</span>
              </div>
              <div className="flow-desc">{s.desc}</div>
              <div className="flow-port">
                <small>{s.portLabel}</small>
                {s.port}
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
