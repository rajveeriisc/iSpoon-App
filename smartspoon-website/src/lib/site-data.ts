export const nav = [
  { label: "How it works", href: "#how-it-works" },
  { label: "Features", href: "#features" },
  { label: "App", href: "#app" },
  { label: "Pricing", href: "#pricing" },
  { label: "FAQ", href: "#faq" },
];

export const heroStats = [
  { value: "100Hz", label: "high-resolution tremor measurement" },
  { value: "10M+", label: "people live with hand tremor worldwide" },
  { value: "4–12 Hz", label: "tremor band the app analyses" },
];

export const howItWorks = [
  {
    step: "01",
    title: "Sensors read the shake",
    body: "Motion sensors in the handle sample hand movement hundreds of times a second, capturing high-fidelity tremor data.",
  },
  {
    step: "02",
    title: "DSP algorithms separate motion",
    body: "Advanced Digital Signal Processing (Welch PSD) isolates the deliberate arc of a bite from the high-frequency noise of tremor.",
  },
  {
    step: "03",
    title: "Data logs in the background",
    body: "Every bite and tremor event syncs to your phone over Bluetooth automatically, even if the app is closed.",
  },
  {
    step: "04",
    title: "Track your progress",
    body: "Build a clear picture of your tremor patterns, meal duration, and symptom trends over weeks and months.",
  },
];

export const features = [
  {
    title: "Precision Tremor Tracking",
    body: "Advanced motion tracking algorithm that silently quantifies hand tremor severity in the background.",
    image: "/images/precision_tracking_ui.png",
  },
  {
    title: "Bluetooth sync to the i-Spoon app",
    body: "Every meal logs automatically — no manual entry. Review history, trends, and tremor intensity over time.",
    image: "/images/bluetooth_sync_spoon.png",
  },
  {
    title: "All-day ergonomic comfort",
    body: "A weighted, contoured grip designed with occupational therapists for people with limited hand strength.",
    image: "/images/ergonomic_grip_spoon.png",
  },
  {
    title: "Food Temperature Monitoring",
    body: "Built-in sensors monitor food temperature. The i-Spoon Pro version even includes an active heater to keep meals warm.",
    image: "/images/food_temp_spoon.png",
  },
];

export const impactStats = [
  { value: "6-axis", label: "accelerometer + gyroscope motion sensing" },
  { value: "100Hz", label: "sampling rate for precise tremor tracking" },
  { value: "BLE 5.0", label: "low-energy link to your phone" },
];

export const trustBadges = [
  "30-Day Money-Back Guarantee",
  "Free US Shipping",
  "1-Year Limited Warranty",
  "Designed With Occupational Therapists",
];

export const comparisonPoints = [
  {
    label: "Objective tremor measurement",
    without: "Relying on subjective memory and brief doctor visits",
    with: "100Hz IMU sensors log your exact tremor frequency and amplitude",
  },
  {
    label: "Medication & Therapy Tracking",
    without: "Guessing if a new treatment is actually working",
    with: "Clear data showing if your steadiness score is improving over time",
  },
  {
    label: "Meal Duration & Bite Counts",
    without: "No insight into how long meals are taking",
    with: "Automatic logging of every bite to track eating fatigue",
  },
  {
    label: "Tracking tremor over time",
    without: "No record beyond what you remember to mention at appointments",
    with: "Every meal logged automatically, charted in the app",
  },
  {
    label: "Caregiver visibility",
    without: "Calling every day to ask 'did you eat?'",
    with: "Remote dashboard shows when meals happened and tremor intensity",
  },
];

export const moreFeatures = [
  {
    icon: "Activity",
    title: "Bite Counting & Temp",
    body: "Automatically logs every bite taken and monitors food temperature for safety and analytics.",
  },
  {
    icon: "Bluetooth",
    title: "Background BLE Sync",
    body: "Reliable auto-sync to the app the moment the spoon powers on — even if your phone is asleep.",
  },
  {
    icon: "BarChart3",
    title: "Tremor analytics dashboard",
    body: "Weekly and monthly trends so you and your care team can see real progress.",
  },
  {
    icon: "Users",
    title: "Caregiver sharing",
    body: "Invite a family member or clinician to view meal history and tremor alerts remotely.",
  },
  {
    icon: "BatteryCharging",
    title: "Long-lasting Battery",
    body: "A reliable battery designed to handle multiple meals throughout the day on a single charge.",
  },
  {
    icon: "ShieldCheck",
    title: "Easy to clean",
    body: "Designed with food-safe materials that are easy to rinse and maintain daily.",
  },
  {
    icon: "Briefcase",
    title: "i-Spoon Pro Heater",
    body: "The Pro model features an integrated heating element to actively maintain your ideal food temperature.",
  },
  {
    icon: "Sparkles",
    title: "Secure Cloud Sync",
    body: "Your meals and motion history sync to your private account so they survive a lost or replaced phone.",
  },
];

export const specs = [
  { label: "Weight", value: "115g (balanced for grip assistance)" },
  { label: "Battery", value: "Rechargeable Li-Ion" },
  { label: "Connectivity", value: "Bluetooth Low Energy 5.0" },
  { label: "Pro Feature", value: "Active Food Heater (30–70°C)" },
  { label: "Materials", value: "Food-grade stainless steel & silicone" },
  { label: "Data sampling", value: "100Hz Welch PSD" },
  { label: "Warranty", value: "1-year limited" },
];

export const scienceStat = {
  eyebrow: "THE ALGORITHM",
  headline: "Precision tremor measurement",
  body: "i-Spoon samples motion 100 times a second and uses an advanced Digital Signal Processing algorithm (Welch PSD) to separate the deliberate arc of a bite (<4Hz) from the high-frequency noise of tremor (4-12Hz). This generates an objective Tremor Score that you can share with your doctor.",
};

export const appScreens = [
  {
    name: "Today",
    headline: "Today's tremor score",
    bigStat: "92",
    bigStatLabel: "steadiness score",
    rows: [
      { label: "Breakfast", detail: "8:12 AM · steady" },
      { label: "Lunch", detail: "1:04 PM · steady" },
      { label: "Snack", detail: "4:30 PM · mild tremor" },
    ],
  },
  {
    name: "Insights",
    headline: "Eating pattern, last 30 days",
    bigStat: "+18%",
    bigStatLabel: "steadier vs. last month",
    rows: [
      { label: "Best day", detail: "Tuesdays · avg. 95 score" },
      { label: "Avg. meal time", detail: "11 min, down from 19" },
      { label: "Bites logged", detail: "412 this month" },
    ],
  },
  {
    name: "Device",
    headline: "i-Spoon connection",
    bigStat: "100%",
    bigStatLabel: "battery · connected",
    rows: [
      { label: "Sensitivity", detail: "Level 3 of 5" },
      { label: "Firmware", detail: "Up to date · v2.4.1" },
      { label: "Last synced", detail: "Just now" },
    ],
  },
];

export const pricing = {
  name: "i-Spoon",
  price: "$249",
  originalPrice: "$299",
  includes: [
    "i-Spoon tracking utensil",
    "Charging cable",
    "Free i-Spoon companion app",
    "1-year limited warranty",
    "30-day money-back guarantee",
  ],
  guarantee: "Try it for 30 days. Log your meals, review the data, and if you don't love the insights, send it back for a full refund.",
};

export const caregiver = {
  eyebrow: "FOR FAMILIES & CAREGIVERS",
  headline: "Stay close, without hovering at every meal",
  body: "Invite caregivers, family, or a clinician into the i-Spoon app to see meal history, tremor trends, and get alerted if something looks off — so your loved one keeps their independence and you keep peace of mind.",
  bullets: [
    "Remote view of meal history and tremor scores",
    "Optional alerts for missed meals or rising tremor",
    "Shareable trend reports for doctor visits",
  ],
};

export const newsletter = {
  headline: "Join the mealtime independence movement",
  body: "Get setup tips, occupational-therapist advice, and early access to new i-Spoon features.",
};

export const faqs = [
  {
    q: "Who is i-Spoon designed for?",
    a: "People who want to track hand steadiness and eating patterns at mealtimes. i-Spoon measures and logs motion — it does not diagnose, treat, or reduce tremor, and it is not a substitute for care from your clinician.",
  },
  {
    q: "How long does the battery last?",
    a: "A full charge is designed to cover a day of meals. We will publish measured runtime figures before shipping.",
  },
  {
    q: "Is the spoon head dishwasher safe?",
    a: "The detachable head is hand-wash recommended to protect the sensor seal. The handle housing is water-resistant for everyday wiping and cleaning.",
  },
  {
    q: "Do I need the app to use the spoon?",
    a: "The spoon logs data internally, but the app is required to view your Tremor Score, meal history, and share reports with your doctor.",
  },
  {
    q: "Does insurance cover i-Spoon?",
    a: "i-Spoon is a wellness and self-tracking device, not a medical device, so it is generally not reimbursable. We provide an itemized receipt on request.",
  },
];

export const footer = {
  tagline:
    "Hand-steadiness and mealtime tracking you can review yourself or bring to an appointment.",
  social: [
    { label: "Instagram", href: "#" },
    { label: "Facebook", href: "#" },
    { label: "Twitter", href: "#" },
  ],
  columns: [
    {
      heading: "Product",
      links: [
        { label: "How it works", href: "#how-it-works" },
        { label: "Features", href: "#features" },
        { label: "Technical specs", href: "#features" },
        { label: "i-Spoon App", href: "#app" },
      ],
    },
    {
      heading: "Support",
      links: [
        { label: "FAQ", href: "#faq" },
        { label: "Shipping & returns", href: "#" },
        { label: "Warranty", href: "#" },
        { label: "Contact us", href: "mailto:hello@i-spoon.com" },
      ],
    },
    {
      heading: "Company",
      links: [
        { label: "About us", href: "#" },
        { label: "The technology", href: "#science" },
        { label: "For clinicians", href: "#" },
        { label: "Press kit", href: "#" },
      ],
    },
  ],
};
