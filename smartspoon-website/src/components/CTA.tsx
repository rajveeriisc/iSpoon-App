"use client";

import { motion } from "framer-motion";

export default function CTA() {
  return (
    <section className="relative overflow-hidden bg-surface-card py-24 sm:py-32">
      {/* Background glow */}
      <div className="pointer-events-none absolute inset-0" aria-hidden>
        <div className="absolute left-1/2 top-1/2 h-96 w-96 -translate-x-1/2 -translate-y-1/2 rounded-full bg-amber/[0.07] blur-[80px]" />
      </div>

      <div className="relative mx-auto max-w-3xl px-5 text-center lg:px-8">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6 }}
        >
          <span className="section-label">Ready?</span>
          <h2 className="mt-5 text-balance font-serif text-5xl font-bold text-text-primary sm:text-6xl">
            Your next steady meal{" "}
            <span className="gradient-text">starts here</span>
          </h2>
          <p className="mt-6 text-lg text-text-secondary">
            Try i-Spoon for 30 days. If it doesn&apos;t change your mealtimes,
            send it back for a full refund — no questions asked.
          </p>

          <div className="mt-10 flex flex-col items-center gap-4 sm:flex-row sm:justify-center">
            <a
              href="#get-smartspoon"
              className="inline-flex items-center gap-2 rounded-xl bg-amber px-9 py-4 text-base font-bold text-[#1a0f07] transition-all hover:bg-amber-light hover:shadow-[0_0_30px_rgba(199,123,67,0.35)] active:scale-95"
            >
              Get i-Spoon — $249
            </a>
            <a
              href="#faq"
              className="text-sm font-medium text-text-muted transition-colors hover:text-text-secondary"
            >
              Read FAQ first →
            </a>
          </div>

          <p className="mt-6 text-xs text-text-muted">
            30-day money-back · Free US shipping
          </p>
        </motion.div>
      </div>
    </section>
  );
}
