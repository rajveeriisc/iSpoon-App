"use client";

import Image from "next/image";
import { motion } from "framer-motion";
import { features } from "@/lib/site-data";
import { Zap, Bluetooth, Hand, BatteryCharging } from "lucide-react";

const featureIcons = [Zap, Bluetooth, Hand, BatteryCharging];

const featuresData = [
  {
    title: "Precision Tremor Tracking",
    body: "Advanced motion tracking algorithm that silently quantifies hand tremor severity in the background.",
    image: "/images/precision_tracking_ui.png",
    span: "lg:col-span-8",
    imgHeight: "h-72",
  },
  {
    title: "Bluetooth sync to the i-Spoon app",
    body: "Every meal logs automatically — no manual entry. Review history, trends, and tremor intensity over time.",
    image: "/images/bluetooth_sync_spoon.png",
    span: "lg:col-span-4",
    imgHeight: "h-72",
  },
  {
    title: "All-day ergonomic comfort",
    body: "A weighted, contoured grip designed with occupational therapists for people with limited hand strength.",
    image: "/images/ergonomic_grip_spoon.png",
    span: "lg:col-span-4",
    imgHeight: "h-56",
  },
  {
    title: "Food Temperature Monitoring",
    body: "Built-in sensors monitor food temperature. The i-Spoon Pro version even includes an active heater to keep meals warm.",
    image: "/images/food_temp_spoon.png",
    span: "lg:col-span-8",
    imgHeight: "h-56",
  },
];

export default function Features() {
  return (
    <section id="features" className="bg-bg py-24 sm:py-32">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        {/* Section label + heading */}
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="mx-auto max-w-2xl text-center"
        >
          <span className="section-label">Features</span>
          <h2 className="mt-4 text-balance font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            Built for real meals,{" "}
            <span className="gradient-text">every day</span>
          </h2>
          <p className="mt-5 text-lg text-text-secondary">
            Every detail designed around one goal: getting food from plate to
            mouth on your own, comfortably, meal after meal.
          </p>
        </motion.div>

        {/* Bento grid */}
        <div className="mt-14 grid grid-cols-1 gap-4 lg:grid-cols-12">
          {featuresData.map((feature, index) => (
            <motion.article
              key={feature.title}
              initial={{ opacity: 0, y: 32 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-60px" }}
              transition={{ duration: 0.6, ease: "easeOut", delay: index * 0.1 }}
              className={`group relative overflow-hidden rounded-2xl border border-surface-border bg-surface-card transition-all duration-500 hover:-translate-y-1 hover:border-amber/20 hover:shadow-[0_8px_40px_rgba(0,0,0,0.4)] ${feature.span}`}
            >
              {/* Hover shimmer overlay */}
              <div className="pointer-events-none absolute inset-0 z-10 opacity-0 transition-opacity duration-500 group-hover:opacity-100 animate-shimmer rounded-2xl" aria-hidden />

              {/* Image */}
              <div className={`relative w-full overflow-hidden ${feature.imgHeight}`}>
                <Image
                  src={feature.image}
                  alt={feature.title}
                  fill
                  sizes="(min-width: 1024px) 50vw, 100vw"
                  className="object-cover object-center transition-transform duration-700 group-hover:scale-105"
                />
                {/* Dark gradient overlay at bottom */}
                <div className="absolute inset-x-0 bottom-0 h-24 bg-gradient-to-t from-[#1e1f23] to-transparent" />
              </div>

              {/* Content */}
              <div className="p-6 sm:p-8">
                <div className="mb-3 inline-flex h-9 w-9 items-center justify-center rounded-lg bg-amber/10 border border-amber/15">
                  {(() => { const Icon = featureIcons[index]; return <Icon className="h-4.5 w-4.5 text-amber" strokeWidth={2} aria-hidden />; })()}
                </div>
                <h3 className="font-serif text-xl font-semibold text-text-primary">
                  {feature.title}
                </h3>
                <p className="mt-2 text-sm leading-relaxed text-text-secondary">
                  {feature.body}
                </p>
              </div>
            </motion.article>
          ))}
        </div>
      </div>
    </section>
  );
}
