const fastModeCode = `<span class="c">// Fast Mode adds one field to GPT Responses requests.</span>
{
  <span class="k">"model"</span>: <span class="s">"gpt-6-astra"</span>,
  <span class="k">"service_tier"</span>: <span class="s">"priority"</span>,   <span class="c">// ← Fast Mode</span>
  <span class="k">"reasoning"</span>: { <span class="k">"effort"</span>: <span class="s">"high"</span> }   <span class="c">// ← Droid CLI</span>
}`

export default function FastModeSection() {
  return (
    <section id="fast-mode">
      <div className="container spotlight">
        <div>
          <span className="spot-pill">⚡ Fast Mode</span>
          <h2>A priority lane when you want the answer now.</h2>
          <p>Fast Mode is independent of reasoning effort. Droid still picks thinking. DroidProxy only asks the lab for a faster path — OpenAI priority for GPT, or the Cursor Agent CLI <span className="mono">-fast</span> suffix for Composer and Grok.</p>
          <dl className="spot-list">
            <dt>GPT</dt>
            <dd>Injects <span className="mono">service_tier: priority</span> for GPT 6 Astra, GPT 5.6 Terra, Luna, and Sol</dd>
            <dt>Cursor · Beta</dt>
            <dd>Appends <span className="mono">-fast</span> to Composer 2.5 and Cursor Grok 4.6 via the local Agent CLI</dd>
            <dt>Grok OAuth</dt>
            <dd>Diverts <span className="mono">grok-4.6</span> onto that same Cursor fast path — <span className="mono">api.x.ai</span> has no fast variant</dd>
            <dt>Reasoning</dt>
            <dd>Left untouched. You still pick the thinking level per session in Droid CLI</dd>
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
