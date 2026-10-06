import type { Metadata, Viewport } from "next";
import { ThemeProvider } from "@/components/ThemeProvider";
import "./globals.css";

export const SITE_DESCRIPTION =
  "The i-Spoon provides precision tremor tracking and mealtime analytics, so people with Parkinson's, essential tremor, and MS can gain objective insights into their symptoms. High-resolution 100Hz measurement.";

export const metadata: Metadata = {
  title: "i-Spoon — Eat Steady, Live Independent",
  description: SITE_DESCRIPTION,
  keywords: [
    "smart spoon",
    "tremor tracking spoon",
    "Parkinson's eating aid",
    "essential tremor utensil",
    "assistive eating technology",
    "i-Spoon",
    "i-Spoon",
  ],
  openGraph: {
    title: "i-Spoon — Eat Steady, Live Independent",
    description:
      "Precision tremor tracking and mealtime analytics so you and your doctor can see the real picture. Built for Parkinson's, essential tremor, and MS.",
    type: "website",
    locale: "en_US",
    siteName: "i-Spoon",
    images: [
      {
        url: "/images/og-image.jpg",
        width: 1200,
        height: 630,
        alt: "i-Spoon — Precision Tremor Tracking",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: "i-Spoon",
    description:
      "High-resolution 100Hz tremor tracking at the spoon tip. Bluetooth-connected, app-tracked, and meticulously designed.",
    images: ["/images/og-image.jpg"],
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  themeColor: "#121317",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
      </head>
      <body className="antialiased">
        <ThemeProvider>{children}</ThemeProvider>
      </body>
    </html>
  );
}
