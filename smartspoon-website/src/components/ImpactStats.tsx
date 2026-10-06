"use client";

import { motion } from "framer-motion";
import { impactStats } from "@/lib/site-data";

export default function ImpactStats() {
  return (
    <section className="relative overflow-hidden bg-surface-card py-20 sm:py-24">
      {/* Glow */}
      <div className="pointer-events-none absolute inset-0" aria-hidden>
        <div className="absolute left-1/3 top-0 h-72 w-72 -translate-x-1/2 rounded-full bg-amber/[0.07] blur-[80px]" />
      </div>

      <div className="relative mx-auto max-w-7xl px-5 lg:px-8">
        <div className="grid grid-cols-1 gap-px rounded-3xl border border-surface-border overflow-hidden sm:grid-cols-3">
          {impactStats.map((stat, i) => (
            <motion.div
              key={stat.label}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-60px" }}
              transition={{ duration: 0.55, ease: "easeOut", delay: i * 0.1 }}
              className="flex flex-col items-center justify-center bg-surface-card px-8 py-12 text-center"
            >
              <div className="font-serif text-6xl font-bold text-amber sm:text-7xl">
                {stat.value}
              </div>
              <p className="mt-4 max-w-[180px] text-sm leading-snug text-text-muted">
                {stat.label}
              </p>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
