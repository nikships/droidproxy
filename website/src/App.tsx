import Navbar from './components/Navbar'
import HeroSection from './components/HeroSection'
import ProvidersSection from './components/ProvidersSection'
import UseCasesSection from './components/UseCasesSection'
import HowItWorksSection from './components/HowItWorksSection'
import ModelsSection from './components/ModelsSection'
import FastModeSection from './components/FastModeSection'
import FeaturesSection from './components/FeaturesSection'
import InstallSection from './components/InstallSection'
import SpecsSection from './components/SpecsSection'
import FaqSection from './components/FaqSection'
import ShowcaseVideoSection from './components/ShowcaseVideoSection'
import ClosingCTA from './components/ClosingCTA'
import Footer from './components/Footer'

function App() {
  return (
    <>
      <Navbar />
      <main>
        <HeroSection />
        <ProvidersSection />
        <UseCasesSection />
        <HowItWorksSection />
        <ModelsSection />
        <FastModeSection />
        <FeaturesSection />
        <InstallSection />
        <SpecsSection />
        <FaqSection />
        <ShowcaseVideoSection />
        <ClosingCTA />
      </main>
      <Footer />
    </>
  )
}

export default App
