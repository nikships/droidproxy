import Eyebrow from './Eyebrow'
import { noOrphan } from '../typography'

const cases = [
  {
    index: '01',
    tag: 'Stop paying twice',
    title: 'Factory tokens are API-priced. Your Claude and ChatGPT plans are not.',
    body: 'Factory bills per token because they pay full API rates upstream. Consumer subscriptions from Anthropic, OpenAI, Google, xAI, Meta, and the rest are subsidized. DroidProxy lets Droid ride those plans instead of a second bill.',
    footLabel: 'You pay',
    footValue: 'the lab you already use',
    footRight: 'BYO plan',
  },
  {
    index: '02',
    tag: 'Same Droid',
    title: 'Nothing about Factory Droid changes.',
    body: 'One click writes custom models into ~/.factory/settings.json. Restart the session, pick “DroidProxy: Fable 5.1” or “DroidProxy: GPT 6 Astra,” and keep using /model, skills, missions, and the rest of the CLI.',
    footLabel: 'Setup',
    footValue: 'install · sign in · apply',
    footRight: '1 click',
  },
  {
    index: '03',
    tag: 'Mix labs',
    title: 'Fable 5.1, GPT 6 Astra, Grok 4.7 — one picker.',
    body: 'Connect Claude, ChatGPT, Antigravity, Copilot, Grok, Kimi, Muse, or Junie. Each account stays on your Mac. Disable any provider without touching the others.',
    footLabel: 'Providers',
    footValue: '8 labs',
    footRight: 'OAuth',
  },
]

export default function UseCasesSection() {
  return (
    <section id="why">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="01">Why it exists</Eyebrow>
            <h2>Stop paying twice for the same models.</h2>
          </div>
          <p>{noOrphan('You already pay the labs. Factory Droid talks to those same models and charges a steep markup to handle billing. DroidProxy removes that extra bill.')}</p>
        </div>

        <div className="usecase-grid">
          {cases.map((c) => (
            <div className="usecase" key={c.index}>
              <Eyebrow index={c.index}>{c.tag}</Eyebrow>
              <h3>{c.title}</h3>
              <p>{noOrphan(c.body)}</p>
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
