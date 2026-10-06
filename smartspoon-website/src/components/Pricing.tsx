"use client";

import { motion } from "framer-motion";
import { pricing } from "@/lib/site-data";
import { Check, Shield, Truck, CreditCard, Clock } from "lucide-react";

const guarantees = [
  { icon: Shield, label: "30-day money-back" },
  { icon: Truck,  label: "Free US shipping" },
  { icon: Clock,  label: "1-year warranty" },
];

export default function Pricing() {
  return (
    <section id="get-smartspoon" className="bg-surface-card py-24 sm:py-32">
      <div className="mx-auto max-w-5xl px-5 lg:px-8">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="text-center"
        >
          <span className="section-label">Pricing</span>
          <h2 className="mt-5 font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            Simple, honest pricing
          </h2>
          <p className="mt-4 text-text-secondary">
            One device. Everything included. No subscription required.
          </p>
        </motion.div>

        <motion.div
          initial={{ opacity: 0, y: 32 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.7, ease: "easeOut", delay: 0.1 }}
          className="mt-14 overflow-hidden rounded-3xl border border-surface-border bg-bg"
        >
          {/* Urgency banner */}
          <div className="bg-amber/10 border-b border-amber/15 px-8 py-3 text-center">
            <p className="text-xs font-semibold text-amber-light tracking-wide">
              Launch pricing — save $50
            </p>
          </div>

          <div className="grid grid-cols-1 gap-0 lg:grid-cols-5">
            {/* Price col */}
            <div className="flex flex-col justify-center border-b border-surface-border px-8 py-10 lg:col-span-2 lg:border-b-0 lg:border-r">
              <p className="font-serif text-6xl font-bold text-text-primary">
                {pricing.price}
              </p>
              <p className="mt-1 text-sm text-text-muted">
                <span className="line-through">{pricing.originalPrice}</span> launch price
              </p>
              <p className="mt-3 text-xs text-text-muted">
              </p>

              <div className="mt-8 flex flex-col gap-3">
                <a
                  href="#"
                  className="block w-full rounded-xl bg-amber py-4 text-center text-base font-bold text-[#1a0f07] transition-all hover:bg-amber-light hover:shadow-[0_0_30px_rgba(199,123,67,0.3)] active:scale-[0.98]"
                >
                  Order i-Spoon →
                </a>
                <p className="text-center text-xs text-text-muted">
                  Ships in 3–5 business days
                </p>
              </div>

              {/* Guarantee badges */}
              <div className="mt-8 grid grid-cols-2 gap-3">
                {guarantees.map(({ icon: Icon, label }) => (
                  <div key={label} className="flex items-center gap-2 rounded-lg border border-surface-border bg-white/[0.03] px-3 py-2">
                    <Icon className="h-3.5 w-3.5 flex-none text-amber" aria-hidden />
                    <span className="text-[11px] font-medium text-text-muted">{label}</span>
                  </div>
                ))}
              </div>
            </div>

            {/* Includes col */}
            <div className="px-8 py-10 lg:col-span-3">
              <p className="section-label mb-6">What&apos;s included</p>
              <ul className="flex flex-col gap-4">
                {pricing.includes.map((item) => (
                  <li key={item} className="flex items-start gap-3">
                    <span className="flex h-5 w-5 flex-none items-center justify-center rounded-full bg-amber/15 mt-0.5">
                      <Check className="h-3 w-3 text-amber" strokeWidth={3} aria-hidden />
                    </span>
                    <span className="text-sm text-text-secondary">{item}</span>
                  </li>
                ))}
              </ul>

              <div className="mt-10 rounded-2xl border border-amber/15 bg-amber/[0.06] p-5">
                <p className="text-sm font-medium text-amber-light">
                  💬 {pricing.guarantee}
                </p>
              </div>
            </div>
          </div>
        </motion.div>
      </div>
    </section>
  );
}
