"use client";

import { motion } from "framer-motion";
import { scienceStat } from "@/lib/site-data";

// A handful of jagged path variants representing raw hand tremor. Cycling
// between them on a loop reads as a continuous, erratic wobble.
const tremorPaths = [
  "M0,40 L15,18 L30,52 L45,12 L60,46 L75,20 L90,50 L105,16 L120,44 L135,22 L150,48 L165,14 L180,42 L195,24 L210,50 L225,18 L240,40",
  "M0,30 L15,48 L30,14 L45,44 L60,20 L75,52 L90,16 L105,42 L120,12 L135,46 L150,22 L165,50 L180,18 L195,44 L210,16 L225,48 L240,28",
  "M0,46 L15,14 L30,40 L45,20 L60,50 L75,16 L90,44 L105,24 L120,48 L135,12 L150,40 L165,22 L180,52 L195,18 L210,42 L225,20 L240,38",
];

// A calm, nearly-flat sine-like curve representing the filtered output.
const smoothPath =
  "M0,32 C20,28 40,36 60,32 C80,28 100,34 120,31 C140,28 160,33 180,30 C200,28 220,32 240,30";

export default function Science() {
  return (
    <section id="science" className="bg-roast py-24 sm:py-28">
      <div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-16 px-6 lg:grid-cols-2 lg:gap-12 lg:px-8">
        {/* Left column: copy */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
        >
          <span className="text-sm font-semibold tracking-[0.2em] text-honey">
            {scienceStat.eyebrow}
          </span>
          <h2 className="mt-4 text-balance font-serif text-4xl font-medium leading-[1.1] text-cream sm:text-5xl">
            {scienceStat.headline}
          </h2>
          <p className="mt-6 max-w-md text-lg leading-relaxed text-oat/70">
            {scienceStat.body}
          </p>
        </motion.div>

        {/* Right column: animated tremor-vs-output diagram */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, ease: "easeOut", delay: 0.1 }}
          className="rounded-3xl border border-cream/10 bg-cream/5 p-8"
        >
          <div className="flex flex-col gap-10">
            <div>
              <p className="text-sm font-medium text-paprika/70">
                Raw hand tremor
              </p>
              <svg
                viewBox="0 0 240 64"
                className="mt-3 h-16 w-full"
                preserveAspectRatio="none"
                aria-hidden
              >
                <motion.path
                  d={tremorPaths[0]}
                  animate={{ d: tremorPaths }}
                  transition={{
                    duration: 1.6,
                    repeat: Infinity,
                    repeatType: "loop",
                    ease: "easeInOut",
                  }}
                  fill="none"
                  className="text-paprika/70"
                  stroke="currentColor"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </div>

            <div className="h-px w-full bg-cream/10" />

            <div>
              <p className="text-sm font-medium text-sage">
                i-Spoon output
              </p>
              <svg
                viewBox="0 0 240 64"
                className="mt-3 h-16 w-full"
                preserveAspectRatio="none"
                aria-hidden
              >
                <motion.path
                  d={smoothPath}
                  animate={{ y: [0, -2, 0, 2, 0] }}
                  transition={{
                    duration: 5,
                    repeat: Infinity,
                    repeatType: "loop",
                    ease: "easeInOut",
                  }}
                  fill="none"
                  className="text-sage"
                  stroke="currentColor"
                  strokeWidth="2.5"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </svg>
            </div>
          </div>

          <p className="mt-8 text-center text-xs tracking-wide text-oat/50">
            Same hand. Same bite. The noise cancels out before it reaches the
            spoon head.
          </p>
        </motion.div>
      </div>
    </section>
  );
}
