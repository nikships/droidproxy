import Eyebrow from './Eyebrow'

export default function ShowcaseVideoSection() {
  return (
    <section id="showcase-video" className="showcase-video-section">
      <div className="container">
        <div className="section-head">
          <div>
            <Eyebrow index="09">Walkthrough</Eyebrow>
            <h2>See the local path in motion.</h2>
          </div>
          <p>Menu bar setup, localhost proxy, model registration, and provider routing — the same loop the install steps describe.</p>
        </div>

        <div className="showcase-video-card">
          <video
            className="showcase-video"
            controls
            aria-label="DroidProxy overview video with English captions"
            preload="metadata"
            poster="/assets/video/droidproxy-overview-poster.png"
          >
            <source src="/assets/video/droidproxy-overview.mp4" type="video/mp4" />
            <track
              kind="captions"
              src="/assets/video/droidproxy-overview.en.vtt"
              srcLang="en"
              label="English"
              default
            />
          </video>
        </div>
      </div>
    </section>
  )
}
