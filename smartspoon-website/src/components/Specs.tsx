"use client";

import { motion } from "framer-motion";
import { specs } from "@/lib/site-data";

export default function Specs() {
  return (
    <section id="specs" className="bg-cream py-24 sm:py-28">
      <div className="mx-auto max-w-5xl px-6">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="text-sm font-semibold tracking-[0.2em] text-caramel">
            SPECS
          </span>
          <h2 className="mt-4 text-balance font-serif text-4xl text-roast sm:text-5xl">
            The details, for the record
          </h2>
          <p className="mt-4 text-roast-soft">
            Every measurement and material, laid out plainly — because trust
            is built in the details, not just the headline.
          </p>
        </motion.div>

        <div className="mt-16 grid grid-cols-1 gap-x-12 sm:grid-cols-2">
          {specs.map((spec, index) => (
            <motion.div
              key={spec.label}
              initial={{ opacity: 0, y: 16 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-80px" }}
              transition={{
                duration: 0.5,
                ease: "easeOut",
                delay: index * 0.06,
              }}
              className="flex flex-col border-b border-line py-4"
            >
              <span className="text-sm uppercase tracking-wide text-roast-soft">
                {spec.label}
              </span>
              <span className="mt-1 font-serif text-lg text-roast">
                {spec.value}
              </span>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
