"use client";

import Image from "next/image";
import { motion } from "framer-motion";

const stats = [
  { value: "100 Hz", label: "motion sampling at the spoon tip" },
  { value: "4–12 Hz", label: "tremor band the app analyses" },
  { value: "6-axis", label: "accelerometer and gyroscope on every bite" },
];

export default function DoctorTrust() {
  return (
    <section id="science" className="bg-bg py-24 sm:py-32">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        {/* Heading */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6 }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="section-label">Built With Clinicians</span>
          <h2 className="mt-5 font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            Trusted by{" "}
            <span className="gradient-text">occupational therapists</span>
          </h2>
          <p className="mt-5 text-lg text-text-secondary">
            i-Spoon was designed with input from occupational therapists. It is a
            wellness and self-tracking tool — not a medical device, and not a
            diagnostic instrument.
          </p>
        </motion.div>

        <div className="mt-14 grid grid-cols-1 gap-8 lg:grid-cols-2 lg:gap-12 items-center">
          {/* LEFT: Doctor image */}
          <motion.div
            initial={{ opacity: 0, x: -30 }}
            whileInView={{ opacity: 1, x: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.7 }}
            className="relative"
          >
            <div className="overflow-hidden rounded-3xl">
              <div className="aspect-[4/3] w-full relative">
                <Image
                  src="/images/doctor-trust.jpg"
                  alt="Occupational therapist reviewing i-Spoon tremor data on a tablet with an elderly patient"
                  fill
                  sizes="(min-width: 1024px) 50vw, 100vw"
                  className="object-cover"
                />
              </div>
            </div>
          </motion.div>

          {/* RIGHT: Stats + copy */}
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6, delay: 0.1 }}
            className="lg:pl-6"
          >
            <div className="grid grid-cols-1 gap-5">
              {stats.map((stat, i) => (
                <motion.div
                  key={stat.value}
                  initial={{ opacity: 0, x: 20 }}
                  whileInView={{ opacity: 1, x: 0 }}
                  viewport={{ once: true }}
                  transition={{ duration: 0.5, delay: 0.15 + i * 0.1 }}
                  className="flex items-center gap-5 rounded-2xl border border-surface-border bg-surface-card px-6 py-5"
                >
                  <div className="font-serif text-4xl font-bold text-amber">
                    {stat.value}
                  </div>
                  <p className="text-sm leading-snug text-text-secondary">
                    {stat.label}
                  </p>
                </motion.div>
              ))}
            </div>

            {/* Animated tremor vs stable diagram */}
            <div className="mt-8 rounded-2xl border border-surface-border bg-surface-card p-6">
              <p className="section-label mb-5">The Algorithm</p>
              <div className="flex flex-col gap-6">
                <div>
                  <p className="text-xs font-medium text-[#d86a4b] mb-2">Raw hand tremor</p>
                  <svg viewBox="0 0 240 40" className="h-10 w-full" preserveAspectRatio="none" aria-hidden>
                    <polyline
                      points="0,20 15,6 30,34 45,8 60,30 75,10 90,32 105,6 120,28 135,10 150,32 165,8 180,26 195,12 210,30 225,8 240,20"
                      fill="none"
                      stroke="#d86a4b"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                    />
                  </svg>
                </div>
                <div className="h-px bg-white/[0.06]" />
                <div>
                  <p className="text-xs font-medium text-[#9db089] mb-2">i-Spoon output</p>
                  <svg viewBox="0 0 240 40" className="h-10 w-full" preserveAspectRatio="none" aria-hidden>
                    <path
                      d="M0,20 C30,18 60,22 90,20 C120,18 150,21 180,19 C200,18 220,20 240,20"
                      fill="none"
                      stroke="#9db089"
                      strokeWidth="2.5"
                      strokeLinecap="round"
                    />
                  </svg>
                </div>
              </div>
              <p className="mt-4 text-center text-xs text-text-muted">
                Same hand. Same bite. The noise cancels before it reaches the spoon head.
              </p>
            </div>
          </motion.div>
        </div>
      </div>
    </section>
  );
}
