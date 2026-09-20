import { providers } from '../content'
import { noOrphan } from '../typography'

export default function ProvidersSection() {
  return (
    <section className="providers" id="providers">
      <div className="container">
        <div className="providers-head">
          <span className="logos-label">Bring your own subscription</span>
          <p>{noOrphan('Sign in to the labs you already have. Unused labs stay off.')}</p>
        </div>
        <div className="providers-grid">
          {providers.map((p) => (
            <div className="provider-chip" key={p.name}>
              <img src={p.icon} alt="" />
              <div>
                <b>{p.name}</b>
                <span><span className="provider-lab">{p.lab} · </span>{p.note}</span>
              </div>
            </div>
          ))}
        </div>
      </div>
    </section>
  )
}
