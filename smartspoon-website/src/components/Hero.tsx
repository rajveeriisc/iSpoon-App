"use client";

import Image from "next/image";
import { motion } from "framer-motion";
import { heroStats } from "@/lib/site-data";

const particles = Array.from({ length: 16 }, (_, i) => ({
  id: i,
  x: `${Math.random() * 100}%`,
  y: `${20 + Math.random() * 60}%`,
  size: 2 + Math.random() * 3,
  duration: 4 + Math.random() * 5,
  delay: Math.random() * 4,
}));

export default function Hero() {
  return (
    <section
      id="hero"
      className="relative min-h-screen overflow-hidden bg-bg pt-28 pb-20 sm:pt-36 sm:pb-28"
    >
      {/* ─── Background layers ─── */}
      <div className="pointer-events-none absolute inset-0" aria-hidden>
        {/* Radial ambient glow – amber upper left */}
        <div className="absolute -top-40 -left-20 h-[42rem] w-[42rem] rounded-full bg-amber/[0.06] blur-[100px]" />
        {/* Radial ambient glow – warm lower right */}
        <div className="absolute bottom-0 right-0 h-[36rem] w-[36rem] rounded-full bg-[#c77b43]/[0.05] blur-[90px]" />
        {/* Dot grid overlay */}
        <div
          className="absolute inset-0 opacity-[0.18]"
          style={{
            backgroundImage:
              "radial-gradient(circle, rgba(199,123,67,0.35) 1px, transparent 1px)",
            backgroundSize: "32px 32px",
            maskImage:
              "radial-gradient(ellipse 70% 70% at 60% 40%, black 0%, transparent 80%)",
          }}
        />
      </div>

      {/* ─── Floating particles ─── */}
      <div className="pointer-events-none absolute inset-0" aria-hidden>
        {particles.map((p) => (
          <span
            key={p.id}
            className="absolute rounded-full bg-amber/50"
            style={{
              left: p.x,
              top: p.y,
              width: p.size,
              height: p.size,
              animation: `particle-rise ${p.duration}s ${p.delay}s ease-in infinite`,
            }}
          />
        ))}
      </div>

      <div className="relative mx-auto grid max-w-7xl grid-cols-1 items-center gap-12 px-5 lg:grid-cols-2 lg:gap-8 lg:px-8">
        {/* ─── LEFT: Copy ─── */}
        <div className="order-2 lg:order-1">
          {/* Pill badge */}
          <motion.div
            initial={{ opacity: 0, y: 20 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.55, ease: "easeOut" }}
          >
            <span className="inline-flex items-center gap-2 rounded-full border border-amber/20 bg-amber/10 px-4 py-1.5 text-xs font-semibold tracking-widest text-amber-light">
              <span className="relative flex h-2 w-2">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-amber opacity-60" style={{ animationDuration: "2s" }} />
                <span className="relative inline-flex h-2 w-2 rounded-full bg-amber" />
              </span>
              ESSENTIAL TREMOR · PARKINSON&apos;S · MS
            </span>
          </motion.div>

          {/* Headline */}
          <motion.h1
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.08 }}
            className="mt-7 text-balance font-serif text-5xl font-bold leading-[1.06] text-text-primary sm:text-6xl lg:text-7xl"
          >
            Eat steady.
            <br />
            <span className="gradient-text">Live independent.</span>
          </motion.h1>

          {/* Sub-copy */}
          <motion.p
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.16 }}
            className="mt-6 max-w-lg text-lg leading-relaxed text-text-secondary"
          >
            i-Spoon tracks hand tremor 100× per second and logs it
            silently — building a clear picture of your symptoms so you
            and your doctor can see what's really happening.
          </motion.p>

          {/* CTAs */}
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.24 }}
            className="mt-9 flex flex-wrap items-center gap-4"
          >
            <a
              href="#get-smartspoon"
              className="inline-flex items-center gap-2 rounded-lg bg-amber px-7 py-3.5 text-sm font-bold text-[#1a0f07] transition-all hover:bg-amber-light hover:shadow-[0_0_24px_rgba(199,123,67,0.4)] active:scale-95"
            >
              Get i-Spoon
              <svg viewBox="0 0 16 16" fill="none" className="h-4 w-4" aria-hidden>
                <path d="M3 8h10M9 4l4 4-4 4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </a>
            <a
              href="#how-it-works"
              className="inline-flex items-center gap-2 rounded-lg border border-white/15 px-7 py-3.5 text-sm font-medium text-text-secondary transition-all hover:border-amber/30 hover:text-text-primary"
            >
              <svg viewBox="0 0 16 16" fill="none" className="h-4 w-4" aria-hidden>
                <circle cx="8" cy="8" r="7" stroke="currentColor" strokeWidth="1.5"/>
                <path d="M6 5.5l5 2.5-5 2.5V5.5z" fill="currentColor"/>
              </svg>
              See how it works
            </a>
          </motion.div>

          {/* App Store badges */}
          <motion.div
            initial={{ opacity: 0, y: 16 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.55, ease: "easeOut", delay: 0.32 }}
            className="mt-6 flex items-center gap-3"
          >
            <a href="#app" className="inline-flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3.5 py-2 text-xs font-medium text-text-muted transition-colors hover:border-white/20 hover:text-text-secondary">
              <svg viewBox="0 0 24 24" fill="currentColor" className="h-4 w-4" aria-hidden><path d="M18.71 19.5c-.83 1.24-1.71 2.45-3.05 2.47-1.34.03-1.77-.79-3.29-.79-1.53 0-2 .77-3.27.82-1.31.05-2.3-1.32-3.14-2.53C4.25 17 2.94 12.45 4.7 9.39c.87-1.52 2.43-2.48 4.12-2.51 1.28-.02 2.5.87 3.29.87.78 0 2.26-1.07 3.8-.91.65.03 2.47.26 3.64 1.98-.09.06-2.17 1.28-2.15 3.81.03 3.02 2.65 4.03 2.68 4.04-.03.07-.42 1.44-1.38 2.83M13 3.5c.73-.83 1.94-1.46 2.94-1.5.13 1.17-.34 2.35-1.04 3.19-.69.85-1.83 1.51-2.95 1.42-.15-1.15.41-2.35 1.05-3.11z"/></svg>
              App Store
            </a>
            <a href="#app" className="inline-flex items-center gap-2 rounded-lg border border-white/10 bg-white/[0.04] px-3.5 py-2 text-xs font-medium text-text-muted transition-colors hover:border-white/20 hover:text-text-secondary">
              <svg viewBox="0 0 24 24" fill="currentColor" className="h-4 w-4" aria-hidden><path d="M3.18 23.76c.35.21.79.22 1.17.02l12.53-7.1-2.69-2.76-11.01 9.84zm15.26-8.81L16.2 12.5l2.24-2.45 3.29 1.85a1.25 1.25 0 0 1 0 2.2l-3.29 1.85zm-3.9-4.35L3.01.4C2.7.19 2.33.17 2 .35L14.54 13l2-2.4zM2 .35C1.65.54 1.43.9 1.43 1.28v21.44c0 .38.22.74.57.93L14.54 11 2 .35z"/></svg>
              Google Play
            </a>
          </motion.div>

          {/* Stats bar */}
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.38 }}
            className="mt-12 grid grid-cols-3 gap-6 border-t border-surface-border pt-8 sm:max-w-lg"
          >
            {heroStats.map((stat, i) => (
              <motion.div
                key={stat.label}
                initial={{ opacity: 0, y: 16 }}
                animate={{ opacity: 1, y: 0 }}
                transition={{ duration: 0.5, ease: "easeOut", delay: 0.44 + i * 0.07 }}
              >
                <div className="font-serif text-3xl font-bold text-amber sm:text-4xl">
                  {stat.value}
                </div>
                <div className="mt-1.5 text-xs leading-snug text-text-muted">
                  {stat.label}
                </div>
              </motion.div>
            ))}
          </motion.div>
        </div>

        {/* ─── RIGHT: Product image ─── */}
        <motion.div
          initial={{ opacity: 0, scale: 0.94, y: 30 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          transition={{ duration: 0.9, ease: "easeOut", delay: 0.12 }}
          className="relative order-1 mx-auto flex w-full max-w-sm items-center justify-center lg:order-2 lg:max-w-none"
        >
          {/* Ambient glow rings */}
          <div className="pointer-events-none absolute inset-0 flex items-center justify-center" aria-hidden>
            <div className="h-80 w-80 rounded-full bg-amber/[0.08] blur-[60px]" />
            <div className="absolute h-48 w-48 rounded-full bg-amber/[0.12] blur-[40px]" />
          </div>

          {/* Floating spoon */}
          <div className="animate-float relative z-10 aspect-square w-full max-w-[380px] drop-shadow-[0_60px_80px_rgba(0,0,0,0.7)] lg:max-w-[420px]">
            <Image
              src="/images/hero-spoon-v2.png"
              alt="i-Spoon — premium smart spoon with OLED handle display, floating on dark background with amber glow"
              fill
              priority
              sizes="(min-width: 1024px) 420px, (min-width: 640px) 380px, 85vw"
              className="object-contain"
            />
          </div>
        </motion.div>
      </div>

      {/* ─── Scroll hint ─── */}
      <motion.div
        initial={{ opacity: 0 }}
        animate={{ opacity: 1 }}
        transition={{ delay: 1.2, duration: 0.6 }}
        className="absolute bottom-8 left-1/2 -translate-x-1/2"
        aria-hidden
      >
        <div className="flex flex-col items-center gap-2">
          <span className="text-[10px] font-semibold tracking-[0.2em] text-text-muted">SCROLL</span>
          <div className="h-8 w-px bg-gradient-to-b from-amber/30 to-transparent" />
        </div>
      </motion.div>
    </section>
  );
}
