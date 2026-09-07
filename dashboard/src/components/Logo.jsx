export function Logo({ className = '', size = 40 }) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 40 40"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      aria-hidden="true"
    >
      <rect width="40" height="40" rx="10" fill="url(#logo-bg)" />
      {/* Window / browser frame */}
      <rect x="8" y="10" width="24" height="20" rx="4" stroke="url(#logo-fg)" strokeWidth="1.8" fill="none" opacity="0.9" />
      <line x1="8" y1="15" x2="32" y2="15" stroke="url(#logo-fg)" strokeWidth="1.2" opacity="0.6" />
      {/* Local server dot */}
      <circle cx="20" cy="24" r="3.5" fill="url(#logo-accent)" />
      <defs>
        <linearGradient id="logo-bg" x1="0" y1="0" x2="40" y2="40" gradientUnits="userSpaceOnUse">
          <stop stopColor="#243044" />
          <stop offset="1" stopColor="#1a2332" />
        </linearGradient>
        <linearGradient id="logo-fg" x1="8" y1="10" x2="32" y2="30" gradientUnits="userSpaceOnUse">
          <stop stopColor="#94a3b8" />
          <stop offset="1" stopColor="#64748b" />
        </linearGradient>
        <linearGradient id="logo-accent" x1="16" y1="20" x2="24" y2="28" gradientUnits="userSpaceOnUse">
          <stop stopColor="#38bdf8" />
          <stop offset="1" stopColor="#0ea5e9" />
        </linearGradient>
      </defs>
    </svg>
  );
}
