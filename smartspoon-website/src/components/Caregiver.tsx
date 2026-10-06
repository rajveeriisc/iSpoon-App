"use client";

import Image from "next/image";
import { motion } from "framer-motion";
import { caregiver } from "@/lib/site-data";
import { Check } from "lucide-react";

export default function Caregiver() {
  return (
    <section className="bg-bg py-24 sm:py-32">
      <div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-14 px-5 lg:grid-cols-2 lg:gap-16 lg:px-8">
        {/* LEFT: Image */}
        <motion.div
          initial={{ opacity: 0, x: -30 }}
          whileInView={{ opacity: 1, x: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, ease: "easeOut" }}
          className="relative overflow-hidden rounded-3xl"
        >
          <div className="aspect-[4/3] w-full">
            <Image
              src="/images/caregiver-family.jpg"
              alt="Multi-generational family dining together — elderly grandparent eating independently with i-Spoon while family smiles"
              fill
              sizes="(min-width: 1024px) 50vw, 100vw"
              className="object-cover"
            />
          </div>
          {/* Overlay badge */}
          <div className="absolute bottom-5 left-5 flex items-center gap-3 rounded-xl border border-white/10 bg-black/60 px-4 py-3 backdrop-blur-md">
            <span className="relative flex h-2.5 w-2.5">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-green-400 opacity-60" style={{ animationDuration: "2s" }} />
              <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-green-400" />
            </span>
            <span className="text-xs font-semibold text-white">Caregiver alerts — all quiet</span>
          </div>
        </motion.div>

        {/* RIGHT: Copy */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut", delay: 0.1 }}
        >
          <span className="section-label">{caregiver.eyebrow}</span>
          <h2 className="mt-5 text-balance font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            {caregiver.headline}
          </h2>
          <p className="mt-6 text-lg leading-relaxed text-text-secondary">
            {caregiver.body}
          </p>

          <ul className="mt-9 flex flex-col gap-4">
            {caregiver.bullets.map((bullet, i) => (
              <motion.li
                key={bullet}
                initial={{ opacity: 0, x: 20 }}
                whileInView={{ opacity: 1, x: 0 }}
                viewport={{ once: true, margin: "-60px" }}
                transition={{ duration: 0.5, ease: "easeOut", delay: 0.2 + i * 0.08 }}
                className="flex items-start gap-3"
              >
                <span className="flex h-6 w-6 flex-none items-center justify-center rounded-full bg-amber/15 border border-amber/20 mt-0.5">
                  <Check className="h-3.5 w-3.5 text-amber" strokeWidth={2.5} aria-hidden />
                </span>
                <span className="text-sm leading-relaxed text-text-secondary">{bullet}</span>
              </motion.li>
            ))}
          </ul>

          <motion.a
            initial={{ opacity: 0, y: 12 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-60px" }}
            transition={{ duration: 0.5, delay: 0.5 }}
            href="#pricing"
            className="mt-10 inline-flex items-center gap-2 rounded-lg border border-amber/25 bg-amber/10 px-6 py-3 text-sm font-semibold text-amber-light transition-all hover:bg-amber/15 hover:border-amber/40"
          >
            Learn about caregiver sharing →
          </motion.a>
        </motion.div>
      </div>
    </section>
  );
}
