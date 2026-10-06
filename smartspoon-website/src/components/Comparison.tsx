"use client";

import { motion } from "framer-motion";
import { Check, Minus } from "lucide-react";
import { comparisonPoints } from "@/lib/site-data";

export default function Comparison() {
  return (
    <section id="comparison" className="bg-cream py-24 sm:py-28">
      <div className="mx-auto max-w-6xl px-6">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="text-sm font-semibold tracking-[0.2em] text-caramel">
            THE DIFFERENCE
          </span>
          <h2 className="mt-4 text-balance font-serif text-4xl text-roast sm:text-5xl">
            What changes at the table
          </h2>
          <p className="mt-4 text-roast-soft">
            The same hand, the same meal — a steadier outcome. Here is what
            mealtime actually looks like before and after i-Spoon.
          </p>
        </motion.div>

        {/* Column headers — desktop only */}
        <div className="mt-16 hidden grid-cols-[1fr_1.4fr_1.4fr] gap-4 px-2 lg:grid">
          <span aria-hidden />
          <span className="text-sm font-semibold tracking-wide text-roast-tertiary">
            Without i-Spoon
          </span>
          <span className="text-sm font-semibold tracking-wide text-caramel">
            With i-Spoon
          </span>
        </div>

        <div className="mt-6 flex flex-col gap-5 lg:mt-2 lg:gap-4">
          {comparisonPoints.map((point, index) => (
            <motion.div
              key={point.label}
              initial={{ opacity: 0, y: 24 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-80px" }}
              transition={{
                duration: 0.6,
                ease: "easeOut",
                delay: index * 0.1,
              }}
              className="grid grid-cols-1 gap-3 lg:grid-cols-[1fr_1.4fr_1.4fr] lg:items-stretch lg:gap-4"
            >
              <div className="flex items-center font-serif text-lg text-roast lg:text-xl">
                {point.label}
              </div>

              <div className="flex items-start gap-3 rounded-2xl bg-canvas p-5">
                <Minus
                  className="mt-0.5 h-5 w-5 shrink-0 text-roast-tertiary"
                  strokeWidth={2.25}
                  aria-hidden
                />
                <div>
                  <p className="text-xs font-semibold tracking-wide text-roast-tertiary lg:hidden">
                    Without i-Spoon
                  </p>
                  <p className="mt-1 text-sm leading-relaxed text-roast-soft sm:text-base lg:mt-0">
                    {point.without}
                  </p>
                </div>
              </div>

              <div className="flex items-start gap-3 rounded-2xl border border-caramel/30 bg-cream p-5 shadow-[0_1px_0_0_rgba(199,123,67,0.08)]">
                <Check
                  className="mt-0.5 h-5 w-5 shrink-0 text-sage-deep"
                  strokeWidth={2.25}
                  aria-hidden
                />
                <div>
                  <p className="text-xs font-semibold tracking-wide text-caramel lg:hidden">
                    With i-Spoon
                  </p>
                  <p className="mt-1 text-sm leading-relaxed text-roast sm:text-base lg:mt-0">
                    {point.with}
                  </p>
                </div>
              </div>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
