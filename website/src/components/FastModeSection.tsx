const fastModeCode = `<span class="c">// Fast Mode adds one field to your GPT requests.</span>
{
  <span class="k">"model"</span>: <span class="s">"gpt-5.5"</span>,
  <span class="k">"service_tier"</span>: <span class="s">"priority"</span>,   <span class="c">// ← added by Fast Mode</span>
  <span class="k">"reasoning"</span>: { <span class="k">"effort"</span>: <span class="s">"high"</span> }   <span class="c">// ← chosen in Droid CLI</span>
}`

export default function FastModeSection() {
  return (
    <section id="fast-mode" style={{ background: 'var(--bg-alt)' }}>
      <div className="container spotlight">
        <div>
          <span className="spot-pill">⚡ Fast Mode</span>
          <h2>A priority lane for GPT.</h2>
          <p>Flip Fast Mode and DroidProxy asks OpenAI to run your GPT requests on the priority service tier — same model, same reasoning effort, just lower latency when you want the answer now.</p>
          <dl className="spot-list">
            <dt>What it does</dt>
            <dd>Adds <span className="mono">service_tier: priority</span> to GPT requests on the Responses API for lower-latency responses</dd>
            <dt>Works with</dt>
            <dd>GPT 5.3 Codex, GPT 5.4, and GPT 5.5 — toggle each one in the Settings window</dd>
            <dt>When to use</dt>
            <dd>Interactive sessions where responsiveness matters more than conserving priority capacity</dd>
            <dt>Reasoning effort</dt>
            <dd>Left untouched — you still pick the thinking level per session in Droid CLI</dd>
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
