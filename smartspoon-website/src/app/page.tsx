import Navbar from "@/components/Navbar";
import MobileNav from "@/components/MobileNav";
import Hero from "@/components/Hero";
import TrustBadges from "@/components/TrustBadges";
import HowItWorks from "@/components/HowItWorks";
import Features from "@/components/Features";
import VideoDemo from "@/components/VideoDemo";
import ImpactStats from "@/components/ImpactStats";
import DoctorTrust from "@/components/DoctorTrust";
import SavoraAppScreens from "@/components/SavoraAppScreens";
import Testimonials from "@/components/Testimonials";
import Caregiver from "@/components/Caregiver";
import Pricing from "@/components/Pricing";
import FAQ from "@/components/FAQ";
import Newsletter from "@/components/Newsletter";
import CTA from "@/components/CTA";
import Footer from "@/components/Footer";

export default function Home() {
  return (
    <>
      {/* Scroll progress bar */}
      <div
        id="scroll-progress"
        style={{ width: "0%" }}
        aria-hidden="true"
      />

      <Navbar />

      <main className="pb-20 md:pb-0">
        <Hero />
        <TrustBadges />
        <HowItWorks />
        <Features />
        <VideoDemo />
        <ImpactStats />
        <DoctorTrust />
        <SavoraAppScreens />
        <Testimonials />
        <Caregiver />
        <Pricing />
        <FAQ />
        <Newsletter />
        <CTA />
      </main>

      <Footer />
      
      <MobileNav />

      {/* Scroll progress script */}
      <script
        dangerouslySetInnerHTML={{
          __html: `
            (function() {
              var bar = document.getElementById('scroll-progress');
              if (!bar) return;
              function update() {
                var scrolled = window.scrollY;
                var total = document.documentElement.scrollHeight - window.innerHeight;
                var pct = total > 0 ? (scrolled / total) * 100 : 0;
                bar.style.width = pct + '%';
              }
              window.addEventListener('scroll', update, { passive: true });
              update();
            })();
          `,
        }}
      />
    </>
  );
}
