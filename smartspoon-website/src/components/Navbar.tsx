"use client";

import { useState, useEffect } from "react";
import { nav } from "@/lib/site-data";
import ThemeToggle from "@/components/ThemeToggle";

export default function Navbar() {
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 20);
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <>
      <header
        className={`fixed top-0 left-0 right-0 z-50 transition-all duration-300 ${
          scrolled ? "glass border-b border-surface-border" : "bg-transparent"
        }`}
      >
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-6 px-5 py-4 lg:px-8">
          {/* Logo */}
          <a href="#" className="flex items-center gap-2.5 group">
            <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-amber/10 border border-amber/20 transition-colors group-hover:bg-amber/20">
              <svg viewBox="0 0 24 24" fill="none" className="h-5 w-5 text-amber-light" aria-hidden>
                <path d="M12 3c-1 0-2 .4-2 1.2v4.3L7.5 10a2 2 0 0 0-.5 1.3V19a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2v-7.7a2 2 0 0 0-.5-1.3L14 8.5V4.2C14 3.4 13 3 12 3z" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
              </svg>
            </div>
            <span className="font-serif text-lg font-semibold text-text-primary">
              i<span className="text-amber">Spoon</span>
            </span>
          </a>

          {/* Desktop Nav */}
          <nav className="hidden items-center gap-7 md:flex" aria-label="Main navigation">
            {nav.map((item) => (
              <a
                key={item.href}
                href={item.href}
                className="text-sm font-medium text-text-secondary transition-colors hover:text-text-primary"
              >
                {item.label}
              </a>
            ))}
          </nav>

          <div className="flex items-center gap-3">
            <ThemeToggle />
            {/* CTA */}
            <a
              href="#get-smartspoon"
              className="hidden rounded-lg bg-amber px-5 py-2.5 text-sm font-semibold text-[#1a0f07] transition-all hover:bg-amber-light hover:shadow-[0_0_20px_rgba(199,123,67,0.35)] md:block"
            >
              Get i-Spoon
            </a>
          </div>
        </div>
      </header>

    </>
  );
}
