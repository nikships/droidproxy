import { models } from '../content'
import Eyebrow from './Eyebrow'

export default function ModelsSection() {
  const groups = models.reduce<string[]>((acc, m) => {
    if (!acc.includes(m.group)) acc.push(m.group)
    return acc
  }, [])

  return (
    <section id="models">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="03">Models</Eyebrow>
            <h2>Current flagships, your subscription.</h2>
          </div>
          <p>Reasoning effort is chosen per session in Droid CLI — not in the proxy. DroidProxy registers each model with its native levels so the selector shows every option the lab actually supports.</p>
        </div>

        <div className="table-wrap">
          <table>
            <thead>
              <tr>
                <th style={{ width: '32%' }}>Model</th>
                <th>Effort levels</th>
                <th style={{ width: '16%' }}>Max output</th>
                <th style={{ width: '14%' }}>Provider</th>
              </tr>
            </thead>
            <tbody>
              {groups.map((group) => (
                models
                  .filter((m) => m.group === group)
                  .map((m, i) => (
                    <tr key={m.id} className={i === 0 ? 'group-start' : undefined}>
                      <td className="model-cell">
                        <img src={m.icon} alt="" />
                        <div>
                          {i === 0 && <div className="model-group">{group}</div>}
                          <b>{m.name}</b>
                          <span>{m.id}</span>
                        </div>
                      </td>
                      <td>
                        <div className="levels">
                          {m.levels.map((lvl) => (
                            <span className={lvl === 'max' ? 'level max' : 'level'} key={lvl}>{lvl}</span>
                          ))}
                        </div>
                      </td>
                      <td className="ctx num">
                        {m.max}<small>tok</small>
                        {m.context && <><br /><span className="ctx-extra">{m.context} context</span></>}
                      </td>
                      <td className="ctx">{m.provider}</td>
                    </tr>
                  ))
              ))}
            </tbody>
          </table>
        </div>

        <div className="model-cards">
          {models.map((m) => (
            <article className="model-card" key={m.id}>
              <div className="model-card-top">
                <div className="model-card-name">
                  <img src={m.icon} alt="" />
                  <div>
                    <div className="model-group">{m.group}</div>
                    <b>{m.name}</b>
                    <span>{m.id}</span>
                  </div>
                </div>
                <div className="model-card-meta">
                  {m.max} tok
                  {m.context && <small>{m.context} ctx</small>}
                  <small>{m.provider}</small>
                </div>
              </div>
              <div className="levels">
                {m.levels.map((lvl) => (
                  <span className={lvl === 'max' ? 'level max' : 'level'} key={lvl}>{lvl}</span>
                ))}
              </div>
            </article>
          ))}
        </div>

        <p className="table-note">
          Copilot is account-specific — pick up to three models from your GitHub plan in Settings. Junie serves Fable 5.1, Opus 5, and Sonnet 5 from a JetBrains AI subscription. Image models (Grok Imagine, GPT Image) are separate skills, not chat entries.
        </p>
      </div>
    </section>
  )
}
