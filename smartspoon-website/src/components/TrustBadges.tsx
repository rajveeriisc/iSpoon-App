"use client";

import { motion } from "framer-motion";
import { trustBadges } from "@/lib/site-data";
import { Shield, Truck, Clock, Stethoscope, HeartHandshake, Headphones } from "lucide-react";

const icons = [Shield, Truck, Clock, Stethoscope, HeartHandshake, Headphones];

export default function TrustBadges() {
  return (
    <section className="border-y border-surface-border bg-surface-card py-8">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        <motion.div
          initial={{ opacity: 0, y: 16 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-40px" }}
          transition={{ duration: 0.5 }}
          className="flex flex-wrap items-center justify-center gap-3 md:gap-4"
        >
          {trustBadges.map((badge, i) => {
            const Icon = icons[i] ?? Shield;
            return (
              <div
                key={badge}
                className="group flex items-center gap-2.5 rounded-full border border-surface-border bg-white/[0.03] px-4 py-2.5 transition-all hover:border-amber/20 hover:bg-amber/[0.05]"
              >
                <Icon className="h-3.5 w-3.5 flex-none text-amber/70 transition-colors group-hover:text-amber" aria-hidden />
                <span className="text-xs font-medium text-text-muted transition-colors group-hover:text-text-secondary">
                  {badge}
                </span>
              </div>
            );
          })}
        </motion.div>
      </div>
    </section>
  );
}
