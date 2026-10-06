"use client";

import { motion } from "framer-motion";
import { Star } from "lucide-react";
import { testimonials } from "@/lib/site-data";

const avatarColors = ["bg-amber/20", "bg-sage/20", "bg-paprika/20"];
const avatarTextColors = ["text-amber-light", "text-sage", "text-[#d86a4b]"];

export default function Testimonials() {
  return (
    <section id="stories" className="bg-surface-card py-24 sm:py-32">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6, ease: "easeOut" }}
          className="text-center"
        >
          <span className="section-label">Stories</span>
          <h2 className="mt-5 text-balance font-serif text-4xl font-bold text-text-primary sm:text-5xl">
            Mealtime independence,{" "}
            <span className="gradient-text">back in their hands</span>
          </h2>
        </motion.div>

        <div className="mt-14 grid grid-cols-1 gap-6 md:grid-cols-3">
          {testimonials.map((t, i) => (
            <motion.div
              key={t.name}
              initial={{ opacity: 0, y: 32 }}
              whileInView={{ opacity: 1, y: 0 }}
              viewport={{ once: true, margin: "-60px" }}
              transition={{ duration: 0.6, ease: "easeOut", delay: i * 0.1 }}
              className="relative flex flex-col rounded-2xl border border-surface-border bg-bg p-7 transition-all hover:-translate-y-1 hover:border-amber/15 hover:shadow-[0_8px_30px_rgba(0,0,0,0.4)]"
            >
              {/* Quotation mark decoration */}
              <div className="absolute -top-3 left-7 font-serif text-6xl leading-none text-amber/20 select-none" aria-hidden>
                &ldquo;
              </div>

              {/* Stars */}
              <div className="flex gap-0.5 mb-5">
                {Array.from({ length: 5 }).map((_, j) => (
                  <Star key={j} className="h-4 w-4 fill-amber text-amber" aria-hidden />
                ))}
              </div>

              {/* Quote */}
              <blockquote className="flex-1 text-sm leading-relaxed text-text-secondary">
                &ldquo;{t.quote}&rdquo;
              </blockquote>

              {/* Author */}
              <div className="mt-7 flex items-center gap-3 border-t border-surface-border pt-5">
                <div
                  className={`flex h-10 w-10 flex-none items-center justify-center rounded-full border border-white/10 text-sm font-bold ${avatarColors[i]} ${avatarTextColors[i]}`}
                  aria-hidden
                >
                  {t.name.charAt(0)}
                </div>
                <div>
                  <p className="text-sm font-semibold text-text-primary">{t.name}</p>
                  <p className="text-xs text-text-muted">{t.detail}</p>
                </div>
              </div>
            </motion.div>
          ))}
        </div>
      </div>
    </section>
  );
}
