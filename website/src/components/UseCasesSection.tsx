const cases = [
  {
    tag: '01 — Save money',
    title: 'Factory tokens are expensive. Your Claude Pro plan isn\'t.',
    body: 'Factory bills per token because they pay full API rates upstream. Big AI labs subsidize their own consumer plans — so a $20 Claude or ChatGPT subscription gets you way more usage than the equivalent Factory tokens.',
    footLabel: 'You pay',
    footValue: 'only the AI lab',
    footRight: 'BYO plan',
  },
  {
    tag: '02 — Same Droid',
    title: 'Nothing about Factory Droid changes.',
    body: 'DroidProxy installs custom models in your Factory client with one click. Pick "DroidProxy: Opus 4.8" instead of the default — same UI, same agent, same models. Your subscription handles the bill.',
    footLabel: 'Setup',
    footValue: 'install · sign in · apply',
    footRight: '1 click',
  },
  {
    tag: '03 — Pick your lab',
    title: 'Mix and match Claude, ChatGPT & Gemini.',
    body: 'Got a Claude Pro plan? Use Opus 4.8 and Sonnet 4.6. ChatGPT Plus? Run GPT-5 inside Droid. Gemini Advanced? Same. Sign in to whichever ones you have — the rest just stay disabled.',
    footLabel: 'Models',
    footValue: '7 supported · all optional',
    footRight: '3 labs',
  },
]

export default function UseCasesSection() {
  return (
    <section id="use-cases">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 01 — Why it exists</div>
            <h2 style={{ marginTop: 10 }}>Stop paying twice for the same models.</h2>
          </div>
          <p>You already pay Anthropic, OpenAI, or Google for Claude, ChatGPT, and Gemini. Factory Droid is just another coding agent that talks to those same models — and they charge a steep markup to handle billing for you. DroidProxy cuts the middleman.</p>
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
