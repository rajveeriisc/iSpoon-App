"use client";

import { Home, Sparkles, Smartphone, DollarSign } from "lucide-react";
import { useEffect, useState } from "react";

const mobileNavItems = [
  { label: "Home", href: "#", icon: Home },
  { label: "Features", href: "#features", icon: Sparkles },
  { label: "App", href: "#app", icon: Smartphone },
  { label: "Pricing", href: "#pricing", icon: DollarSign },
];

export default function MobileNav() {
  const [active, setActive] = useState("#");

  useEffect(() => {
    const handleHashChange = () => {
      setActive(window.location.hash || "#");
    };
    window.addEventListener("hashchange", handleHashChange);
    return () => window.removeEventListener("hashchange", handleHashChange);
  }, []);

  return (
    <div className="fixed bottom-0 left-0 right-0 z-50 border-t border-surface-border bg-surface/90 pb-safe pt-2 backdrop-blur-xl md:hidden">
      <nav className="flex items-center justify-around px-2 pb-2">
        {mobileNavItems.map((item) => {
          const Icon = item.icon;
          const isActive = active === item.href;
          return (
            <a
              key={item.label}
              href={item.href}
              onClick={() => setActive(item.href)}
              className="flex flex-col items-center gap-1 p-2"
            >
              <div
                className={`flex h-8 w-8 items-center justify-center rounded-full transition-colors ${
                  isActive
                    ? "bg-amber/15 text-amber"
                    : "text-text-muted hover:bg-surface-card hover:text-text-primary"
                }`}
              >
                <Icon className="h-5 w-5" strokeWidth={isActive ? 2.5 : 2} />
              </div>
              <span
                className={`text-[10px] font-medium transition-colors ${
                  isActive ? "text-amber" : "text-text-muted"
                }`}
              >
                {item.label}
              </span>
            </a>
          );
        })}
      </nav>
    </div>
  );
}
