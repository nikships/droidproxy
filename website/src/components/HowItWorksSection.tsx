const steps = [
  {
    num: '01',
    name: 'You sign in',
    desc: 'Click a button in the DroidProxy menu bar. A normal browser login window opens for Claude, ChatGPT, Gemini, or Kimi — the same one you\'ve already used a hundred times.',
    portLabel: 'handled by',
    port: 'DroidProxy',
  },
  {
    num: '02',
    name: 'DroidProxy holds the login',
    desc: 'Tokens stay on your Mac. DroidProxy refreshes them in the background so nothing ever expires mid-session — no API keys, no copy-paste, no .env files. The menu bar dropdown also shows your live Claude and Codex rate limit windows, so you always know how much subscription budget is left before the next reset.',
    portLabel: 'stored at',
    port: '~/.cli-proxy-api',
  },
  {
    num: '03',
    name: 'Factory Droid uses it',
    desc: 'Click "Apply" once and DroidProxy adds custom models to your Factory client. Pick one and Droid sends every request to DroidProxy — which forwards to Anthropic, OpenAI, Google, or Moonshot on your subscription.',
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
          <p>DroidProxy lives in your menu bar. You sign in to Claude, ChatGPT, Gemini, or Kimi through it — exactly like signing in to those apps anywhere else. Then it tells Factory Droid "use these subscriptions instead of your own billing."</p>
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
