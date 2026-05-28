import { useCopyToClipboard } from '../hooks/useCopyToClipboard'
import { ArrowRightIcon } from './icons'

const codePlain = `// What "Apply" writes for you — no need to touch this yourself.
"customModels": [
  {
    "model": "claude-opus-4-8",
    "id": "custom:droidproxy:opus-4-8",
    "index": 0,
    "baseUrl": "http://localhost:8317",
    "apiKey": "***",
    "displayName": "DroidProxy: Opus 4.8",
    "maxOutputTokens": 128000,
    "provider": "anthropic"
  },
  {
    "model": "claude-sonnet-4-6",
    "id": "custom:droidproxy:sonnet-4-6",
    "index": 1,
    "baseUrl": "http://localhost:8317",
    "apiKey": "***",
    "displayName": "DroidProxy: Sonnet 4.6",
    "maxOutputTokens": 64000,
    "provider": "anthropic"
  },
  {
    "model": "gpt-5.5",
    "id": "custom:droidproxy:gpt-5.5",
    "index": 4,
    "baseUrl": "http://localhost:8317/v1",
    "apiKey": "***",
    "displayName": "DroidProxy: GPT 5.5",
    "maxOutputTokens": 128000,
    "provider": "openai"
  },
  {
    "model": "gemini-3.1-pro-preview",
    "id": "custom:droidproxy:gemini-3.1-pro",
    "index": 5,
    "baseUrl": "http://localhost:8317/v1",
    "apiKey": "***",
    "displayName": "DroidProxy: Gemini 3.1 Pro",
    "maxOutputTokens": 65536,
    "provider": "openai"
  }
  // + GPT 5.3 Codex, GPT 5.4, Gemini 3 Flash
]`

const codeHtml = `<span class="c">// What "Apply" writes for you — no need to touch this yourself.</span>
<span class="k">"customModels"</span>: [
  {
    <span class="k">"model"</span>: <span class="s">"claude-opus-4-8"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:opus-4-8"</span>,
    <span class="k">"index"</span>: <span class="n">0</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: Opus 4.8"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">128000</span>,
    <span class="k">"provider"</span>: <span class="s">"anthropic"</span>
  },
  {
    <span class="k">"model"</span>: <span class="s">"claude-sonnet-4-6"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:sonnet-4-6"</span>,
    <span class="k">"index"</span>: <span class="n">1</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: Sonnet 4.6"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">64000</span>,
    <span class="k">"provider"</span>: <span class="s">"anthropic"</span>
  },
  {
    <span class="k">"model"</span>: <span class="s">"gpt-5.5"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:gpt-5.5"</span>,
    <span class="k">"index"</span>: <span class="n">4</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317/v1"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: GPT 5.5"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">128000</span>,
    <span class="k">"provider"</span>: <span class="s">"openai"</span>
  },
  {
    <span class="k">"model"</span>: <span class="s">"gemini-3.1-pro-preview"</span>,
    <span class="k">"id"</span>: <span class="s">"custom:droidproxy:gemini-3.1-pro"</span>,
    <span class="k">"index"</span>: <span class="n">5</span>,
    <span class="k">"baseUrl"</span>: <span class="s">"http://localhost:8317/v1"</span>,
    <span class="k">"apiKey"</span>: <span class="s">"***"</span>,
    <span class="k">"displayName"</span>: <span class="s">"DroidProxy: Gemini 3.1 Pro"</span>,
    <span class="k">"maxOutputTokens"</span>: <span class="n">65536</span>,
    <span class="k">"provider"</span>: <span class="s">"openai"</span>
  }
  <span class="c">// + GPT 5.3 Codex, GPT 5.4, Gemini 3 Flash</span>
]`

export default function InstallSection() {
  const { copy, copied } = useCopyToClipboard()

  const handleCopy = () => {
    copy(codePlain)
  }

  return (
    <section id="install">
      <div className="container">
        <div className="section-head">
          <div>
            <div className="meta">§ 04 — Install</div>
            <h2 style={{ marginTop: 10 }}>Setup takes about a minute.</h2>
          </div>
          <p>Download, sign in, click apply. DroidProxy stays in your menu bar and updates itself in the background — so you'll never have to do this twice.</p>
        </div>

        <div className="install-grid">
          <div className="steps">
            <div className="step">
              <span className="step-n">01</span>
              <div>
                <h4>Download DroidProxy</h4>
                <p>Grab the latest release from GitHub. Drag it to Applications and open — it lives in your menu bar from then on.</p>
                <div className="step-cta">
                  <a className="btn btn-primary" href="https://github.com/anand-92/droidproxy/releases/latest" target="_blank" rel="noopener">
                    Download for macOS
                    <ArrowRightIcon />
                  </a>
                </div>
              </div>
            </div>

            <div className="step">
              <span className="step-n">02</span>
              <div>
                <h4>Sign in to your AI subscriptions</h4>
                <p>Click the menu bar icon → Settings, then sign in to Claude, ChatGPT, or Gemini. A normal browser login window opens. Sign in to as many or as few as you like.</p>
              </div>
            </div>

            <div className="step">
              <span className="step-n">03</span>
              <div>
                <h4>Click <em style={{ fontStyle: 'normal', color: 'var(--accent)' }}>Apply Factory Models</em></h4>
                <p>One click adds DroidProxy's models to your Factory Droid setup. Restart your Droid session — when you pick "DroidProxy: Opus 4.8" or any of the others, your subscription handles the bill.</p>
              </div>
            </div>

            <div className="step">
              <span className="step-n">04</span>
              <div>
                <h4>That's it.</h4>
                <p>Use Factory Droid like you always have. DroidProxy quietly handles auth in the background and updates itself when there's a new version.</p>
              </div>
            </div>
          </div>

          <div>
            <div className="code-block">
              <div className="code-head">
                <span><span className="mono" style={{ color: 'var(--accent)' }}>$</span> &nbsp; ~/.factory/config.json &nbsp; <span style={{ color: 'var(--dim)' }}>— customModels</span></span>
                <button className="copy" type="button" onClick={handleCopy}>
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
