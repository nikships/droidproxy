import Eyebrow from './Eyebrow'
import { noOrphan } from '../typography'

const fastModeCode = `<span class="c">// Fast Mode: one extra field on GPT Responses.</span>
{
  <span class="k">"model"</span>: <span class="s">"gpt-6-astra"</span>,
  <span class="k">"service_tier"</span>: <span class="s">"priority"</span>,
  <span class="k">"reasoning"</span>: { <span class="k">"effort"</span>: <span class="s">"high"</span> }
}`

export default function FastModeSection() {
  return (
    <section id="fast-mode">
      <div className="container spotlight">
        <div>
          <Eyebrow index="04">Fast Mode</Eyebrow>
          <h2>A priority lane when you want the answer now.</h2>
          <p>{noOrphan('Fast Mode is independent of reasoning effort. Droid still picks thinking. DroidProxy asks OpenAI for the priority service tier on GPT 6 Astra, Sol, and Luna.')}</p>
          <dl className="spot-list">
            <dt>What it does</dt>
            <dd>Injects <span className="mono">service_tier: priority</span> on GPT Responses API calls</dd>
            <dt>Works with</dt>
            <dd>{noOrphan('GPT 6 Astra, Sol, and Luna — toggle each model from Settings')}</dd>
            <dt>Reasoning</dt>
            <dd>{noOrphan('Left untouched. You still pick the thinking level per session inside Droid CLI')}</dd>
          </dl>
        </div>
        <div className="code-block">
          <div className="code-head">
            <span><span className="mono" style={{ color: 'var(--accent)' }}>$</span> &nbsp; POST /v1/responses &nbsp; <span style={{ color: 'var(--dim)' }}>— Fast Mode on</span></span>
          </div>
          <pre
            className="code-body"
            dangerouslySetInnerHTML={{ __html: fastModeCode }}
          />
        </div>
      </div>
    </section>
  )
}
