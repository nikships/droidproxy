import { useCopyToClipboard } from '../hooks/useCopyToClipboard'
import { ArrowRightIcon } from './icons'
import { RELEASES } from '../content'

const codePlain = `// What "Apply" writes — no need to edit this yourself.
"customModels": [
  {
    "model": "claude-fable-5-1",
    "id": "custom:droidproxy:fable-5-1",
    "baseUrl": "http://localhost:8317",
    "apiKey": "***",
    "displayName": "DroidProxy: Fable 5.1",
    "maxOutputTokens": 128000,
    "provider": "anthropic",
    "enableThinking": true,
    "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
    "defaultReasoningEffort": "xhigh"
  },
  {
    "model": "gpt-6-astra",
    "id": "custom:droidproxy:gpt-6-astra",
    "baseUrl": "http://localhost:8317/v1",
    "apiKey": "***",
    "displayName": "DroidProxy: GPT 6 Astra",
    "maxOutputTokens": 128000,
    "maxContextLimit": 1050000,
    "provider": "openai",
    "enableThinking": true,
    "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max"],
    "defaultReasoningEffort": "medium"
  }
  // + Opus 5, Sonnet 5, GPT 5.6, Gemini 3.8 Flash, Grok 4.6, …
]`

const codeHtml = `<span class="c">// What "Apply" writes — no need to edit this yourself.</span>
<span class="k">"customModels"</span>: [
  {
    <span class="k">"model"</span>: <span class="s">"claude-fable-5-1"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:fable-5-1"</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: Fable 5.1"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">128000</span>,
    <span class="k">"provider"</span>: <span class="s">"anthropic"</span>,
    <span class="k">"enableThinking"</span>: true,
    <span class="k">"supportedReasoningEfforts"</span>: [<span class="s">"low"</span>, <span class="s">"medium"</span>, <span class="s">"high"</span>, <span class="s">"xhigh"</span>, <span class="s">"max"</span>],
    <span class="k">"defaultReasoningEffort"</span>: <span class="s">"xhigh"</span>
  },
  {
    <span class="k">"model"</span>: <span class="s">"gpt-6-astra"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:gpt-6-astra"</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317/v1"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: GPT 6 Astra"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">128000</span>,
    <span class="k">"maxContextLimit"</span>: <span class="n">1050000</span>,
    <span class="k">"provider"</span>: <span class="s">"openai"</span>,
    <span class="k">"enableThinking"</span>: true,
    <span class="k">"supportedReasoningEfforts"</span>: [<span class="s">"low"</span>, <span class="s">"medium"</span>, <span class="s">"high"</span>, <span class="s">"xhigh"</span>, <span class="s">"max"</span>],
    <span class="k">"defaultReasoningEffort"</span>: <span class="s">"medium"</span>
  }
  <span class="c">// + Opus 5, Sonnet 5, GPT 5.6, Gemini 3.8 Flash, Grok 4.6, …</span>
]`

export default function InstallSection() {
  const { copy, copied } = useCopyToClipboard()

  return (
    <section id="install">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 05 — Install</div>
            <h2 style={{ marginTop: 10 }}>Setup takes about a minute.</h2>
          </div>
          <p>Download, sign in, click Apply. DroidProxy stays in the menu bar and updates itself — you should not have to do this twice.</p>
        </div>

        <div className="install-grid">
          <div className="steps">
            <div className="step">
              <span className="step-n">01</span>
              <div>
                <h4>Download DroidProxy</h4>
                <p>Grab the latest Apple Silicon build from GitHub. Unzip, drag to Applications, open — it lives in the menu bar from then on.</p>
                <div className="step-cta">
                  <a className="btn btn-primary" href={RELEASES} target="_blank" rel="noopener">
                    Download for macOS
                    <ArrowRightIcon />
                  </a>
                </div>
              </div>
            </div>

            <div className="step">
              <span className="step-n">02</span>
              <div>
                <h4>Sign in to the labs you already pay</h4>
                <p>Menu bar icon → Settings. Connect Claude, ChatGPT, Gemini, Copilot, Grok, Kimi, Muse, or Junie. A normal browser login opens. Skip anything you do not have.</p>
              </div>
            </div>

            <div className="step">
              <span className="step-n">03</span>
              <div>
                <h4>Click <em style={{ fontStyle: 'normal', color: 'var(--accent)' }}>Apply Factory Models</em></h4>
                <p>One click writes DroidProxy models into Factory. Restart Droid and pick Fable 5.1 or GPT 6 Astra — your subscription handles the bill.</p>
              </div>
            </div>

            <div className="step">
              <span className="step-n">04</span>
              <div>
                <h4>That's it.</h4>
                <p>Use Droid like you always have. Reasoning stays in the CLI selector. DroidProxy refreshes OAuth in the background and Sparkle pulls updates.</p>
              </div>
            </div>
          </div>

          <div>
            <div className="code-block">
              <div className="code-head">
                <span><span className="mono" style={{ color: 'var(--accent)' }}>$</span> &nbsp; ~/.factory/settings.json &nbsp; <span style={{ color: 'var(--dim)' }}>— customModels</span></span>
                <button className="copy" type="button" onClick={() => copy(codePlain)}>
                  {copied ? 'Copied' : 'Copy'}
                </button>
              </div>
              <pre
                className="code-body"
                dangerouslySetInnerHTML={{ __html: codeHtml }}
              />
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
