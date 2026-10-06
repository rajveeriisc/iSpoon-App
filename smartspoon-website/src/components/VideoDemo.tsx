"use client";

import Image from "next/image";
import { useState } from "react";
import { motion, AnimatePresence } from "framer-motion";
import { Play, X } from "lucide-react";

export default function VideoDemo() {
  const [open, setOpen] = useState(false);

  return (
    <>
      <section id="demo" className="bg-surface-card py-24 sm:py-32">
        <div className="mx-auto max-w-7xl px-5 lg:px-8">
          <motion.div
            initial={{ opacity: 0, y: 24 }}
            whileInView={{ opacity: 1, y: 0 }}
            viewport={{ once: true, margin: "-80px" }}
            transition={{ duration: 0.6 }}
            className="mx-auto max-w-2xl text-center"
          >
            <span className="section-label">See it in action</span>
            <h2 className="mt-5 font-serif text-4xl font-bold text-text-primary sm:text-5xl">
              Watch the{" "}
              <span className="gradient-text">data come alive</span>
            </h2>
            <p className="mt-5 text-lg text-text-secondary">
              Watch how i-Spoon tracks tremor data seamlessly in the background — capturing every nuance of your motion without interrupting your meal.
            </p>
          </motion.div>

          {/* Video poster */}
          <motion.div
            initial={{ opacity: 0, scale: 0.97 }}
            whileInView={{ opacity: 1, scale: 1 }}
            viewport={{ once: true, margin: "-60px" }}
            transition={{ duration: 0.7, delay: 0.1 }}
            className="group relative mt-12 overflow-hidden rounded-3xl border border-surface-border"
          >
            {/* Poster image */}
            <div className="relative aspect-video w-full">
              <Image
                src="/images/video_demo_poster.png"
                alt="Video demonstration of i-Spoon tracking hand tremor data"
                fill
                sizes="100vw"
                className="object-cover brightness-50"
              />
              {/* Gradient overlay */}
              <div className="absolute inset-0 bg-gradient-to-t from-black/60 via-transparent to-transparent" />
            </div>

            {/* Play button */}
            <button
              type="button"
              onClick={() => setOpen(true)}
              className="absolute inset-0 flex items-center justify-center"
              aria-label="Play demonstration video"
            >
              <div className="relative">
                {/* Ping ring */}
                <span className="absolute inset-0 rounded-full animate-ping bg-amber/30" style={{ animationDuration: "2.5s" }} aria-hidden />
                <div className="relative flex h-20 w-20 items-center justify-center rounded-full border-2 border-amber/60 bg-amber/10 text-white backdrop-blur-sm transition-all duration-300 group-hover:scale-110 group-hover:bg-amber/20 group-hover:border-amber">
                  <Play className="h-8 w-8 translate-x-0.5 text-white" fill="white" aria-hidden />
                </div>
              </div>
            </button>

            {/* Bottom caption */}
            <div className="absolute bottom-6 left-1/2 -translate-x-1/2 rounded-full border border-white/10 bg-black/60 px-5 py-2 backdrop-blur-sm">
              <p className="whitespace-nowrap text-xs font-medium text-white">
                100Hz high-resolution background measurement
              </p>
            </div>
          </motion.div>
        </div>
      </section>

      {/* Modal */}
      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/80 px-4 backdrop-blur-sm"
            onClick={() => setOpen(false)}
            role="dialog"
            aria-modal="true"
            aria-label="Video player"
          >
            <motion.div
              initial={{ scale: 0.93, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              exit={{ scale: 0.93, opacity: 0 }}
              transition={{ type: "spring", stiffness: 300, damping: 28 }}
              onClick={(e) => e.stopPropagation()}
              className="relative w-full max-w-4xl overflow-hidden rounded-2xl border border-white/10 bg-black"
            >
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="absolute right-4 top-4 z-10 flex h-9 w-9 items-center justify-center rounded-full bg-black/60 text-white backdrop-blur-sm hover:bg-black/80"
                aria-label="Close video"
              >
                <X className="h-5 w-5" />
              </button>
              <div className="aspect-video flex items-center justify-center bg-black text-text-muted text-sm">
                {/* Replace src with actual YouTube embed when available */}
                <p>Video coming soon — connect your YouTube or Vimeo URL here</p>
              </div>
            </motion.div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
