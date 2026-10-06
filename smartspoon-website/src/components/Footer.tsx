"use client";

import { footer } from "@/lib/site-data";

export default function Footer() {
  const year = new Date().getFullYear();

  return (
    <footer className="border-t border-surface-border bg-bg py-16 sm:py-20">
      <div className="mx-auto max-w-7xl px-5 lg:px-8">
        <div className="grid grid-cols-1 gap-12 md:grid-cols-[1.5fr_repeat(3,1fr)]">
          {/* Brand col */}
          <div>
            <a href="#" className="flex items-center gap-2.5 group w-fit">
              <div className="flex h-9 w-9 items-center justify-center rounded-xl bg-amber/10 border border-amber/15">
                <svg viewBox="0 0 24 24" fill="none" className="h-5 w-5 text-amber-light" aria-hidden>
                  <path d="M12 3c-1 0-2 .4-2 1.2v4.3L7.5 10a2 2 0 0 0-.5 1.3V19a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2v-7.7a2 2 0 0 0-.5-1.3L14 8.5V4.2C14 3.4 13 3 12 3z" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
                </svg>
              </div>
              <span className="font-serif text-lg font-semibold text-text-primary">
                i<span className="text-amber">Spoon</span>
              </span>
            </a>
            <p className="mt-5 max-w-xs text-sm leading-relaxed text-text-muted">
              {footer.tagline}
            </p>
            <div className="mt-6 flex items-center gap-3">
              {footer.social?.map((s) => (
                <a
                  key={s.label}
                  href={s.href}
                  aria-label={s.label}
                  className="flex h-9 w-9 items-center justify-center rounded-lg border border-surface-border text-text-muted transition-all hover:border-amber/25 hover:text-amber"
                >
                  {s.label === "Instagram" && (
                    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="2" y="2" width="20" height="20" rx="5"/><circle cx="12" cy="12" r="5"/><circle cx="17.5" cy="6.5" r="1.5"/></svg>
                  )}
                  {s.label === "Facebook" && (
                    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor"><path d="M22 12c0-5.523-4.477-10-10-10S2 6.477 2 12c0 4.991 3.657 9.128 8.438 9.878V14.89h-2.54V12h2.54V9.797c0-2.506 1.492-3.89 3.777-3.89 1.094 0 2.238.195 2.238.195v2.46h-1.26c-1.243 0-1.63.771-1.63 1.562V12h2.773l-.443 2.89h-2.33v6.988C18.343 21.128 22 16.991 22 12z"/></svg>
                  )}
                  {s.label === "Twitter" && (
                    <svg className="h-4 w-4" viewBox="0 0 24 24" fill="currentColor"><path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/></svg>
                  )}
                </a>
              ))}
            </div>
          </div>

          {/* Link columns */}
          {footer.columns.map((col) => (
            <div key={col.heading}>
              <p className="section-label mb-5">{col.heading}</p>
              <ul className="flex flex-col gap-3">
                {col.links.map((link) => (
                  <li key={link.href}>
                    <a
                      href={link.href}
                      className="text-sm text-text-muted transition-colors hover:text-text-primary"
                    >
                      {link.label}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        {/* Bottom bar */}
        <div className="mt-14 flex flex-col items-center justify-between gap-4 border-t border-surface-border pt-8 sm:flex-row">
          <p className="text-xs text-text-muted">
            <span className="block max-w-3xl text-[11px] leading-relaxed text-text-muted">
              i-Spoon is a wellness and self-tracking product. It is not a
              medical device. It does not diagnose, treat, cure or prevent any
              condition, and its measurements are not a clinical assessment.
              Always talk to a qualified healthcare professional about symptoms
              or treatment. Never change medication based on data from this app.
            </span>
            © {year} i-Spoon Technologies. All rights reserved.
          </p>
          <div className="flex items-center gap-5">
            <a href="#" className="text-xs text-text-muted hover:text-text-secondary transition-colors">Privacy Policy</a>
            <a href="#" className="text-xs text-text-muted hover:text-text-secondary transition-colors">Terms of Service</a>
            <a href="#" className="text-xs text-text-muted hover:text-text-secondary transition-colors">Accessibility</a>
          </div>
        </div>
      </div>
    </footer>
  );
}
