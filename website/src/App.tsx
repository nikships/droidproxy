import Navbar from './components/Navbar'
import HeroSection from './components/HeroSection'
import LogosStrip from './components/LogosStrip'
import UseCasesSection from './components/UseCasesSection'
import HowItWorksSection from './components/HowItWorksSection'
import ModelsSection from './components/ModelsSection'
import FastModeSection from './components/FastModeSection'
import InstallSection from './components/InstallSection'
import SpecsSection from './components/SpecsSection'
import ClosingCTA from './components/ClosingCTA'
import Footer from './components/Footer'

function App() {
  return (
    <>
      <Navbar />
      <main>
        <HeroSection />
        <LogosStrip />
        <UseCasesSection />
        <HowItWorksSection />
        <ModelsSection />
        <FastModeSection />
        <InstallSection />
        <SpecsSection />
        <ClosingCTA />
      </main>
      <Footer />
    </>
  )
}

export default App
