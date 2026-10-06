"use client";

import { motion } from "framer-motion";
import { howItWorks } from "@/lib/site-data";

export default function HowItWorks() {
  return (
    <section id="how-it-works" className="bg-bg py-24 sm:py-32">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6 }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="section-label">How it works</span>
          <h2 className="mt-5 text-balance font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            From tremor to steady{" "}
            <span className="gradient-text">in milliseconds</span>
          </h2>
          <p className="mt-5 text-lg text-text-secondary">
            Four precise steps happen invisibly, every time you bring a bite to
            your mouth.
          </p>
        </motion.div>

        {/* Steps */}
        <div className="relative mt-16">
          {/* Connector line (desktop) */}
          <div
            className="pointer-events-none absolute top-8 left-[calc(12.5%+1rem)] right-[calc(12.5%+1rem)] hidden h-px lg:block"
            style={{
              background:
                "linear-gradient(to right, transparent, rgba(199,123,67,0.25) 20%, rgba(199,123,67,0.25) 80%, transparent)",
            }}
            aria-hidden
          />

          <div className="grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-4">
            {howItWorks.map((step, i) => (
              <motion.div
                key={step.step}
                initial={{ opacity: 0, y: 32 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-60px" }}
                transition={{ duration: 0.6, ease: "easeOut", delay: i * 0.1 }}
                className="group relative"
              >
                {/* Step number badge */}
                <div className="relative mx-auto mb-6 flex h-16 w-16 items-center justify-center rounded-2xl border border-amber/20 bg-amber/10 text-amber transition-all group-hover:border-amber/40 group-hover:bg-amber/15 group-hover:shadow-[0_0_20px_rgba(199,123,67,0.15)]">
                  <span className="font-serif text-xl font-bold text-amber">
                    {step.step}
                  </span>
                  {/* Connector dot for desktop */}
                  <div className="absolute -right-[calc(50%+0.5rem)] top-1/2 hidden h-1.5 w-1.5 -translate-y-1/2 rounded-full bg-amber/30 lg:block" aria-hidden />
                </div>

                <h3 className="text-center font-serif text-lg font-semibold text-text-primary sm:text-xl">
                  {step.title}
                </h3>
                <p className="mt-3 text-center text-sm leading-relaxed text-text-secondary">
                  {step.body}
                </p>
              </motion.div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
