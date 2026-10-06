"use client";

import {
  Activity,
  Bluetooth,
  BarChart3,
  Users,
  BatteryCharging,
  ShieldCheck,
  Briefcase,
  Sparkles,
  type LucideIcon,
} from "lucide-react";
import { motion } from "framer-motion";
import { moreFeatures } from "@/lib/site-data";

const iconMap: Record<string, LucideIcon> = {
  Activity,
  Bluetooth,
  BarChart3,
  Users,
  BatteryCharging,
  ShieldCheck,
  Briefcase,
  Sparkles,
};

export default function MoreFeatures() {
  return (
    <section id="more-features" className="bg-oat py-24 sm:py-28">
      <div className="mx-auto max-w-6xl px-6">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="text-sm font-semibold tracking-[0.2em] text-caramel">
            EVERY DETAIL
          </span>
          <h2 className="mt-4 text-balance font-serif text-4xl text-roast sm:text-5xl">
            Designed down to the detail
          </h2>
          <p className="mt-4 text-text-muted">
            Beyond data tracking, every part of i-Spoon — the clinical-grade sensors,
            the battery, the case it travels in — is built to disappear into
            the background of a normal meal.
          </p>
        </motion.div>

        <div className="mt-16 grid grid-cols-1 gap-6 sm:grid-cols-2 lg:grid-cols-4">
          {moreFeatures.map((feature, index) => {
            const Icon = iconMap[feature.icon];
            return (
              <motion.div
                key={feature.title}
                initial={{ opacity: 0, y: 24 }}
                whileInView={{ opacity: 1, y: 0 }}
                viewport={{ once: true, margin: "-80px" }}
                transition={{
                  duration: 0.6,
                  ease: "easeOut",
                  delay: index * 0.06,
                }}
                className="rounded-2xl border border-line bg-cream p-6 transition-all duration-300 hover:-translate-y-1 hover:shadow-md"
              >
                <span className="flex h-10 w-10 items-center justify-center rounded-full bg-caramel/10 text-caramel">
                  <Icon className="h-5 w-5" strokeWidth={2} aria-hidden />
                </span>
                <h3 className="mt-4 text-base font-semibold text-roast sm:text-lg">
                  {feature.title}
                </h3>
                <p className="mt-2 text-sm text-roast-soft">{feature.body}</p>
              </motion.div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
