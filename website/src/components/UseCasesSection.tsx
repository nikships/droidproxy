const cases = [
  {
    tag: '01 — Stop paying twice',
    title: 'Factory tokens are API-priced. Your Claude and ChatGPT plans are not.',
    body: 'Factory bills per token because they pay full API rates upstream. Consumer subscriptions from Anthropic, OpenAI, Google, xAI, Meta, and the rest are subsidized. DroidProxy lets Droid ride those plans instead of a second bill.',
    footLabel: 'You pay',
    footValue: 'the lab you already use',
    footRight: 'BYO plan',
  },
  {
    tag: '02 — Same Droid',
    title: 'Nothing about Factory Droid changes.',
    body: 'One click writes custom models into ~/.factory/settings.json. Restart the session, pick “DroidProxy: Fable 5.1” or “DroidProxy: GPT 6 Astra,” and keep using /model, skills, missions, and the rest of the CLI.',
    footLabel: 'Setup',
    footValue: 'install · sign in · apply',
    footRight: '1 click',
  },
  {
    tag: '03 — Mix labs',
    title: 'Fable 5.1, GPT 6 Astra, Gemini 3.8 Flash, Grok 4.6 — in one picker.',
    body: 'Connect Claude, ChatGPT, Gemini, Copilot, Grok, Kimi, Muse, or Junie. Each account stays on your Mac. Disable any provider without touching the others.',
    footLabel: 'Providers',
    footValue: '8 subscriptions · all optional',
    footRight: 'local OAuth',
  },
]

export default function UseCasesSection() {
  return (
    <section id="why">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 01 — Why it exists</div>
            <h2 style={{ marginTop: 10 }}>Stop paying twice for the same models.</h2>
          </div>
          <p>You already pay the labs. Factory Droid is a great coding agent that talks to those same models — and charges a steep markup to handle billing. DroidProxy cuts the middleman.</p>
        </div>

        <div className="usecase-grid">
          {cases.map((c) => (
            <div className="usecase" key={c.tag}>
              <span className="usecase-tag">{c.tag}</span>
              <h3>{c.title}</h3>
              <p>{c.body}</p>
              <div className="usecase-foot">
                <span><b>{c.footLabel}</b> {c.footValue}</span>
                <span>{c.footRight}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
