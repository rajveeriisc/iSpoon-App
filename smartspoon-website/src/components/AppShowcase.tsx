"use client";

import { useEffect, useState } from "react";
import Image from "next/image";
import { AnimatePresence, motion } from "framer-motion";
import { Bluetooth, TrendingUp, Users } from "lucide-react";
import { appScreens } from "@/lib/site-data";

const features = [
  {
    icon: Bluetooth,
    label: "Auto-sync over Bluetooth",
    body: "Every meal logs the moment you set the spoon down — no manual entry, ever.",
  },
  {
    icon: TrendingUp,
    label: "Tremor trend insights, week over week",
    body: "Watch your steadiness trend in plain language, not just raw numbers.",
  },
  {
    icon: Users,
    label: "Share reports with caregivers or your doctor",
    body: "Export a clean summary in one tap for appointments and check-ins.",
  },
];

const SCREEN_INTERVAL_MS = 3500;

export default function AppShowcase() {
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    const interval = setInterval(() => {
      setActiveIndex((current) => (current + 1) % appScreens.length);
    }, SCREEN_INTERVAL_MS);

    return () => clearInterval(interval);
  }, []);

  const activeScreen = appScreens[activeIndex];

  return (
    <section id="app" className="overflow-hidden bg-bg py-24 sm:py-28">
      <div className="mx-auto grid max-w-7xl grid-cols-1 items-center gap-16 px-5 lg:grid-cols-2 lg:gap-12 lg:px-8">
        {/* Left column: copy */}
        <div>
          <motion.span
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6, ease: "easeOut" }}
            className="section-label"
          >
            THE SMARTSPOON APP
          </motion.span>

          <motion.h2
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.08 }}
            className="mt-6 text-balance font-serif text-4xl font-bold leading-[1.1] text-text-primary sm:text-5xl"
          >
            Your progress, in your pocket
          </motion.h2>

          <motion.p
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.16 }}
            className="mt-6 max-w-md text-lg leading-relaxed text-text-secondary"
          >
            The i-Spoon app turns every meal into a data point — quietly,
            in the background — so you and the people who care for you can
            see steadiness improve over time, not just hope for it.
          </motion.p>

          <motion.ul
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6, ease: "easeOut", delay: 0.24 }}
            className="mt-10 flex flex-col gap-6"
          >
            {features.map((feature, index) => {
              const Icon = feature.icon;
              return (
                <motion.li
                  key={feature.label}
                  initial={{ opacity: 0, y: 16 }}
                  whileInView={{ opacity: 1, y: 0 }}
                  viewport={{ once: true, margin: "-80px" }}
                  transition={{
                    duration: 0.5,
                    ease: "easeOut",
                    delay: 0.3 + index * 0.1,
                  }}
                  className="flex items-start gap-4"
                >
                  <span className="flex h-10 w-10 flex-none items-center justify-center rounded-full bg-amber/10 border border-amber/15 text-amber">
                    <Icon className="h-5 w-5" strokeWidth={2} aria-hidden />
                  </span>
                  <div>
                    <p className="font-medium text-text-primary">{feature.label}</p>
                    <p className="mt-1 text-sm leading-relaxed text-text-secondary">
                      {feature.body}
                    </p>
                  </div>
                </motion.li>
              );
            })}
          </motion.ul>
        </div>

        {/* Right column: cycling app screen phone mockup + supporting product shot */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, ease: "easeOut", delay: 0.1 }}
          className="relative mx-auto flex w-full max-w-md flex-col items-center gap-6 py-6 lg:max-w-none"
        >
          <div className="relative flex justify-center">
            {/* Supporting lifestyle image, peeking from behind the phone */}
            <div className="pointer-events-none absolute right-2 top-10 hidden w-44 overflow-hidden rounded-2xl opacity-80 sm:block sm:w-56 lg:right-6">
              <Image
                src="/images/feature-app-sync.jpg"
                alt="Someone holding a smartphone showing the i-Spoon health tracking app dashboard"
                width={420}
                height={420}
                className="h-auto w-full object-cover drop-shadow-[0_30px_40px_rgba(0,0,0,0.45)]"
                sizes="(min-width: 1024px) 14rem, 11rem"
              />
            </div>

            {/* Phone mockup */}
            <div className="relative z-10 h-[580px] w-[280px] flex-none rounded-[2.5rem] border-8 border-[#0d0e12] bg-bg shadow-[0_50px_80px_rgba(0,0,0,0.7)]">
              {/* Notch */}
              <div
                aria-hidden
                className="absolute left-1/2 top-0 z-20 h-5 w-28 -translate-x-1/2 rounded-b-2xl bg-bg"
              />

              {/* Screen */}
              <div className="relative flex h-full w-full flex-col overflow-hidden rounded-[2rem] bg-surface px-5 pb-6 pt-9">
                {/* Status bar */}
                <div className="flex items-center justify-between text-[11px] font-medium text-text-muted">
                  <span>9:41</span>
                  <span className="flex items-center gap-1">
                    <Bluetooth className="h-3 w-3 text-amber" aria-hidden />
                    Connected
                  </span>
                </div>

                <AnimatePresence mode="wait">
                  <motion.div
                    key={activeScreen.name}
                    initial={{ opacity: 0, x: 32 }}
                    animate={{ opacity: 1, x: 0 }}
                    exit={{ opacity: 0, x: -32 }}
                    transition={{ duration: 0.4, ease: "easeOut" }}
                    className="flex flex-1 flex-col"
                  >
                    {/* Screen header */}
                    <p className="mt-6 text-xs font-medium tracking-wide text-text-muted">
                      {activeScreen.name.toUpperCase()}
                    </p>
                    <p className="mt-1 text-sm font-medium text-text-primary">
                      {activeScreen.headline}
                    </p>

                    {/* Big stat card */}
                    <div className="mt-4 rounded-2xl border border-surface-border bg-amber/10 p-5">
                      <span className="font-serif text-5xl font-bold text-amber">
                        {activeScreen.bigStat}
                      </span>
                      <p className="mt-1 text-xs font-medium tracking-wide text-text-muted">
                        {activeScreen.bigStatLabel.toUpperCase()}
                      </p>
                    </div>

                    {/* Detail rows */}
                    <div className="mt-5 flex flex-col">
                      {activeScreen.rows.map((row) => (
                        <div
                          key={row.label}
                          className="flex items-center justify-between border-b border-surface-border py-3"
                        >
                          <span className="text-sm font-medium text-text-primary">
                            {row.label}
                          </span>
                          <span className="text-xs text-text-muted">
                            {row.detail}
                          </span>
                        </div>
                      ))}
                    </div>
                  </motion.div>
                </AnimatePresence>
              </div>
            </div>
          </div>

          {/* Screen indicators */}
          <div className="flex items-center gap-2.5">
            {appScreens.map((screen, index) => (
              <button
                key={screen.name}
                type="button"
                onClick={() => setActiveIndex(index)}
                aria-label={`Show ${screen.name} screen`}
                aria-current={index === activeIndex}
                className={`h-2 rounded-full transition-all duration-300 ${
                  index === activeIndex
                    ? "w-6 bg-amber"
                    : "w-2 bg-white/20 hover:bg-white/35"
                }`}
              />
            ))}
          </div>
        </motion.div>
      </div>
    </section>
  );
}
