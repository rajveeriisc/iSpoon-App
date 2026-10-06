"use client";

import { useState } from "react";
import { motion } from "framer-motion";
import { newsletter } from "@/lib/site-data";
import { ArrowRight } from "lucide-react";

export default function Newsletter() {
  const [email, setEmail] = useState("");
  const [submitted, setSubmitted] = useState(false);

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (email.trim()) {
      setSubmitted(true);
    }
  };

  return (
    <section className="bg-bg py-20 sm:py-24">
      <div className="mx-auto max-w-2xl px-5 lg:px-8 text-center">
        <motion.div
          initial={{ opacity: 0, y: 24 }}
          whileInView={{ opacity: 1, y: 0 }}
          viewport={{ once: true, margin: "-80px" }}
          transition={{ duration: 0.6 }}
        >
          <span className="section-label">Stay in the loop</span>
          <h2 className="mt-5 font-serif text-3xl font-bold text-text-primary sm:text-4xl">
            {newsletter.headline}
          </h2>
          <p className="mt-4 text-text-secondary">{newsletter.body}</p>

          {submitted ? (
            <motion.div
              initial={{ opacity: 0, scale: 0.95 }}
              animate={{ opacity: 1, scale: 1 }}
              className="mt-8 rounded-2xl border border-amber/20 bg-amber/10 px-8 py-6"
            >
              <p className="text-base font-semibold text-amber-light">
                🎉 You&apos;re on the list!
              </p>
              <p className="mt-1 text-sm text-text-muted">
                We&apos;ll send you tips, updates, and early access to new features.
              </p>
            </motion.div>
          ) : (
            <form
              onSubmit={handleSubmit}
              className="mt-8 flex flex-col gap-3 sm:flex-row sm:gap-2"
              noValidate
            >
              <label htmlFor="newsletter-email" className="sr-only">
                Email address
              </label>
              <input
                id="newsletter-email"
                type="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="your@email.com"
                className="flex-1 rounded-xl border border-white/10 bg-white/[0.04] px-5 py-3.5 text-sm text-text-primary placeholder:text-text-muted outline-none transition-all focus:border-amber/40 focus:bg-white/[0.06] focus:ring-1 focus:ring-amber/20"
              />
              <button
                type="submit"
                className="inline-flex items-center justify-center gap-2 rounded-xl bg-amber px-6 py-3.5 text-sm font-bold text-[#1a0f07] transition-all hover:bg-amber-light hover:shadow-[0_0_20px_rgba(199,123,67,0.3)] active:scale-[0.98]"
              >
                Subscribe
                <ArrowRight className="h-4 w-4" aria-hidden />
              </button>
            </form>
          )}
          <p className="mt-3 text-xs text-text-muted">
            No spam, ever. Unsubscribe any time.
          </p>
        </motion.div>
      </div>
    </section>
  );
}
