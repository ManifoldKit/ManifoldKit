// screens.jsx — LocalImage screen designs
// Each screen renders inside a 402×874 iPhone canvas.

const LI_FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif';
const MONO = 'ui-monospace, "SF Mono", Menlo, monospace';

// ─────────────────────────────────────────────────────────────
// Theme palettes
// ─────────────────────────────────────────────────────────────
const THEMES = {
  paper: {
    name: 'Paper',
    bg: '#F4F1EB',
    surface: '#FBF8F2',
    surfaceAlt: '#EBE6DB',
    ink: '#1C1814',
    inkDim: 'rgba(28,24,20,0.55)',
    inkFaint: 'rgba(28,24,20,0.28)',
    line: 'rgba(28,24,20,0.10)',
    accent: '#1C1814',
    accentInk: '#FBF8F2',
    danger: '#A8412A',
    statusDark: false,
    titleFont: '"Tiempos Headline", "Charter", "Iowan Old Style", Georgia, serif',
  },
  dusk: {
    name: 'Dusk',
    bg: '#0E0D11',
    surface: '#171519',
    surfaceAlt: '#221F25',
    ink: '#F4F1ED',
    inkDim: 'rgba(244,241,237,0.60)',
    inkFaint: 'rgba(244,241,237,0.28)',
    line: 'rgba(244,241,237,0.12)',
    accent: '#F4F1ED',
    accentInk: '#0E0D11',
    danger: '#E08266',
    statusDark: true,
    titleFont: '"Tiempos Headline", "Charter", "Iowan Old Style", Georgia, serif',
  },
};

// Subtly-striped placeholder image — never tries to be a real generated image.
function ImgPlaceholder({ seed = 0, label, theme, style = {}, rounded = 18, alt }) {
  const hues = [
    [22, 200], [180, 320], [140, 30], [260, 40],
    [300, 200], [10, 220], [200, 60], [340, 180],
  ];
  const [h1, h2] = hues[seed % hues.length];
  const dark = theme && theme.statusDark;
  const l1 = dark ? 0.42 : 0.62;
  const l2 = dark ? 0.32 : 0.50;
  return (
    <div role="img" aria-label={alt || label || 'generated image'} style={{
      position: 'relative', overflow: 'hidden', borderRadius: rounded,
      background: `linear-gradient(135deg, oklch(${l1} 0.13 ${h1}) 0%, oklch(${l2} 0.10 ${h2}) 100%)`,
      ...style,
    }}>
      <div style={{
        position: 'absolute', inset: 0,
        background: `repeating-linear-gradient(135deg, rgba(255,255,255,0.07) 0 2px, transparent 2px 9px)`,
        mixBlendMode: 'overlay',
      }} />
      <div style={{
        position: 'absolute', inset: 0,
        background: `radial-gradient(120% 80% at 30% 25%, rgba(255,255,255,0.18) 0%, transparent 55%)`,
      }} />
      {label && (
        <div style={{
          position: 'absolute', left: 12, bottom: 10,
          fontFamily: MONO, fontSize: 9.5, letterSpacing: 0.4, textTransform: 'uppercase',
          color: 'rgba(255,255,255,0.85)',
          textShadow: '0 1px 2px rgba(0,0,0,0.4)',
        }}>{label}</div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// Icons (always pair with aria-label on the parent button)
// ─────────────────────────────────────────────────────────────
const Icon = {
  mic: (s = 22) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="9" y="3" width="6" height="12" rx="3"/><path d="M5 11a7 7 0 0 0 14 0"/><path d="M12 18v3"/>
    </svg>
  ),
  keyboard: (s = 22) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="2.5" y="6" width="19" height="12" rx="2"/>
      <path d="M6 10h.01M9 10h.01M12 10h.01M15 10h.01M18 10h.01M6 14h12"/>
    </svg>
  ),
  share: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 16V4M7 9l5-5 5 5"/><path d="M5 14v5a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-5"/>
    </svg>
  ),
  save: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 4v12M6 11l6 6 6-6"/><path d="M5 20h14"/>
    </svg>
  ),
  refresh: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M3 12a9 9 0 0 1 15.5-6.3L21 8"/><path d="M21 3v5h-5"/>
      <path d="M21 12a9 9 0 0 1-15.5 6.3L3 16"/><path d="M3 21v-5h5"/>
    </svg>
  ),
  edit: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M4 20h4l10-10-4-4L4 16v4z"/><path d="M14 6l4 4"/>
    </svg>
  ),
  close: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M6 6l12 12M6 18L18 6"/>
    </svg>
  ),
  more: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="currentColor" aria-hidden="true">
      <circle cx="5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="19" cy="12" r="1.6"/>
    </svg>
  ),
  cog: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <circle cx="12" cy="12" r="3"/>
      <path d="M12 2v3M12 19v3M4.2 4.2l2.1 2.1M17.7 17.7l2.1 2.1M2 12h3M19 12h3M4.2 19.8l2.1-2.1M17.7 6.3l2.1-2.1"/>
    </svg>
  ),
  download: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 4v12M6 11l6 6 6-6"/><path d="M5 20h14"/>
    </svg>
  ),
  shield: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6l8-3z"/>
    </svg>
  ),
  lock: (s = 16) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <rect x="5" y="11" width="14" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>
    </svg>
  ),
  warn: (s = 20) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 3L2 20h20L12 3z"/><path d="M12 10v5"/><circle cx="12" cy="18" r="0.5" fill="currentColor"/>
    </svg>
  ),
  check: (s = 18) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 12l5 5L20 6"/>
    </svg>
  ),
  back: (s = 22) => (
    <svg width={s} height={s} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M15 5l-7 7 7 7"/>
    </svg>
  ),
};

// IconBtn — accessible icon-only button. ALWAYS requires aria-label.
function IconBtn({ ariaLabel, onClick, children, style = {}, size = 36 }) {
  return (
    <button
      type="button" aria-label={ariaLabel} onClick={onClick}
      style={{
        width: size, height: size, borderRadius: size / 2, border: 'none',
        background: 'transparent', color: 'currentColor', cursor: 'pointer',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: 0, ...style,
      }}>{children}</button>
  );
}

// ─────────────────────────────────────────────────────────────
// 1. First Launch
// ─────────────────────────────────────────────────────────────
function ScreenFirstLaunch({ theme, anim = true }) {
  const [tick, setTick] = React.useState(0);
  React.useEffect(() => {
    if (!anim) return;
    const i = setInterval(() => setTick((t) => t + 1), 2200);
    return () => clearInterval(i);
  }, [anim]);
  const t = THEMES[theme];
  const examples = [
    'a wolf in a snowstorm', 'porcelain teapot, studio light', 'kid astronaut, polaroid',
    'hummingbird mid-flight', 'cathedral of moss', 'ramen shop at midnight',
    '1990s film still, road trip', 'cat in a chef hat', 'paper crane, golden hour',
  ];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, position: 'relative', overflow: 'hidden',
      paddingTop: 60, display: 'flex', flexDirection: 'column',
    }}>
      <div style={{
        flex: 1, padding: '32px 20px 20px',
        display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gridTemplateRows: '1fr 1fr 1fr',
        gap: 8,
      }}>
        {examples.map((ex, i) => {
          const active = i === (tick % 9);
          return (
            <div key={i} style={{
              position: 'relative', aspectRatio: '1', borderRadius: 14, overflow: 'hidden',
              transform: active ? 'scale(1)' : 'scale(0.96)',
              opacity: active ? 1 : 0.55,
              transition: 'opacity 700ms ease, transform 700ms ease',
            }}>
              <ImgPlaceholder seed={i} theme={t} rounded={14} style={{ width: '100%', height: '100%' }} alt={`Example: ${ex}`} />
              {active && (
                <div style={{
                  position: 'absolute', left: 8, right: 8, bottom: 6,
                  fontSize: 9, fontFamily: MONO, color: 'rgba(255,255,255,0.95)',
                  textShadow: '0 1px 3px rgba(0,0,0,0.5)', letterSpacing: 0.2,
                }}>"{ex}"</div>
              )}
            </div>
          );
        })}
      </div>
      <div style={{ padding: '16px 28px 28px' }}>
        <div style={{ fontFamily: t.titleFont, fontSize: 32, lineHeight: 1.05,
          letterSpacing: -0.8, fontWeight: 500, marginBottom: 12 }}>
          Describe an<br/>image. See it.
        </div>
        <div style={{ fontSize: 15, lineHeight: 1.45, color: t.inkDim, marginBottom: 22, maxWidth: 320 }}>
          A 1.4&nbsp;GB model installs once, then runs entirely on your phone — private, offline, no limits.
        </div>
        <button type="button" aria-label="Install model, about two minutes" style={{
          width: '100%', height: 54, borderRadius: 16, border: 'none',
          background: t.accent, color: t.accentInk,
          fontFamily: LI_FONT, fontSize: 17, fontWeight: 600, letterSpacing: -0.2, cursor: 'pointer',
        }}>
          Install model · ~2 min
        </button>
        <div style={{
          fontSize: 12, color: t.inkFaint, textAlign: 'center', marginTop: 12,
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 5,
        }}>
          {Icon.lock(12)} Stays on your device. Always.
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 2. Download
// ─────────────────────────────────────────────────────────────
function ScreenDownload({ theme, progress = 0.42, anim = true }) {
  const [tick, setTick] = React.useState(0);
  const [pct, setPct] = React.useState(progress);
  React.useEffect(() => {
    if (!anim) return;
    const i = setInterval(() => setTick((t) => t + 1), 1800);
    const j = setInterval(() => setPct((p) => Math.min(0.99, p + 0.012)), 600);
    return () => { clearInterval(i); clearInterval(j); };
  }, [anim]);
  const t = THEMES[theme];
  const seeds = [0, 2, 4, 1, 5, 3, 6, 0, 4];
  const prompts = [
    '"a wolf in a snowstorm"', '"porcelain teapot, studio light"',
    '"kid astronaut, polaroid"', '"hummingbird mid-flight"',
    '"cathedral of moss"', '"ramen shop at midnight"',
  ];
  const seed = seeds[tick % seeds.length];
  const promptText = prompts[tick % prompts.length];
  const remainSec = Math.max(8, Math.round((1 - pct) * 130));
  const mins = Math.floor(remainSec / 60);
  const secs = remainSec % 60;
  const remainStr = mins > 0 ? `${mins} min ${secs}s` : `${secs}s`;

  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60, display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ flex: 1, padding: '40px 28px 24px', position: 'relative' }}>
        <div style={{
          width: '100%', aspectRatio: '1', position: 'relative',
          borderRadius: 22, overflow: 'hidden',
          boxShadow: t.statusDark
            ? '0 20px 60px rgba(0,0,0,0.5), inset 0 0 0 1px rgba(255,255,255,0.08)'
            : '0 20px 50px rgba(0,0,0,0.10), inset 0 0 0 1px rgba(0,0,0,0.04)',
        }}>
          <ImgPlaceholder seed={seed} theme={t} rounded={22} style={{ width: '100%', height: '100%' }} alt={`Example output: ${promptText}`} />
          <div style={{ position: 'absolute', inset: 0,
            background: 'linear-gradient(to bottom, transparent 55%, rgba(0,0,0,0.45) 100%)' }} />
          <div style={{ position: 'absolute', left: 18, right: 18, bottom: 16,
            fontFamily: MONO, fontSize: 11.5, letterSpacing: 0.3, color: 'rgba(255,255,255,0.95)' }}>
            {promptText}
          </div>
        </div>
        <div style={{ display: 'flex', gap: 6, marginTop: 12, justifyContent: 'center' }}>
          {[0,1,2,3,4].map((i) => (
            <div key={i} style={{
              width: i === 2 ? 26 : 6, height: 6, borderRadius: 3,
              background: i === 2 ? t.ink : t.inkFaint, transition: 'all 400ms ease',
            }} />
          ))}
        </div>
      </div>
      <div style={{ padding: '12px 28px 32px' }}>
        <div style={{ fontFamily: t.titleFont, fontSize: 22, lineHeight: 1.15,
          letterSpacing: -0.4, fontWeight: 500, marginBottom: 4 }}>
          Installing the model
        </div>
        <div style={{ fontSize: 14, color: t.inkDim, marginBottom: 18, lineHeight: 1.4 }}>
          One-time download. After this, every image stays on your phone.
        </div>
        <div role="progressbar" aria-valuenow={Math.round(pct*100)} aria-valuemin="0" aria-valuemax="100"
          aria-label="Model download progress" style={{
          height: 4, borderRadius: 2, background: t.line, overflow: 'hidden', marginBottom: 10,
        }}>
          <div style={{ height: '100%', width: `${pct * 100}%`, background: t.accent,
            borderRadius: 2, transition: 'width 600ms ease' }} />
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between',
          fontSize: 12, color: t.inkDim, fontVariantNumeric: 'tabular-nums',
          fontFamily: MONO, letterSpacing: 0.2 }}>
          <span>{Math.round(pct * 1400)} / 1,400 MB</span>
          <span>{remainStr} remaining</span>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 3. Empty Prompt — diversity-first suggestions
// ─────────────────────────────────────────────────────────────
function ScreenEmptyPrompt({ theme }) {
  const t = THEMES[theme];
  // Suggestions chosen to demonstrate stylistic range, not just subject matter.
  // Style baked into the prompt itself so taps feed a self-contained string.
  const suggestions = [
    'a photo of a coffee shop window on a rainy morning',
    'an illustration of a fox curled up in a paper-cut forest',
    'a portrait of an elderly fisherman with kind eyes, soft light',
    'an abstract painting of shapes that feel like a slow exhale',
    'a 1970s film still, road movie at golden hour',
    'a 3D render of a tiny ceramic robot on a windowsill',
  ];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, position: 'relative', overflow: 'hidden',
      display: 'flex', flexDirection: 'column', paddingTop: 60,
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: '14px 20px 0' }}>
        <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.2 }}>LocalImage</div>
        <IconBtn ariaLabel="Settings" size={34} style={{ background: t.surface }}>
          {Icon.cog(18)}
        </IconBtn>
      </div>

      <div style={{ flex: 1, display: 'flex', flexDirection: 'column',
        padding: '28px 24px 16px', gap: 18, overflow: 'hidden' }}>
        <div style={{ fontFamily: t.titleFont, fontSize: 28, lineHeight: 1.08,
          letterSpacing: -0.6, fontWeight: 500 }}>
          What do you want<br/>to see?
        </div>
        <div style={{ fontSize: 12, color: t.inkFaint, fontFamily: MONO,
          letterSpacing: 0.6, textTransform: 'uppercase' }}>
          Try one of these — or anything
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          {suggestions.map((s, i) => (
            <button key={i} type="button"
              aria-label={`Use suggestion: ${s}`}
              style={{
                padding: '12px 16px', borderRadius: 12, background: t.surface,
                border: `0.5px solid ${t.line}`, color: t.ink,
                textAlign: 'left', cursor: 'pointer', fontFamily: LI_FONT,
                fontSize: 14, lineHeight: 1.35,
              }}>
              {s}
            </button>
          ))}
        </div>
      </div>

      <div style={{ padding: '0 20px 40px' }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 12,
          background: t.surface, borderRadius: 999,
          padding: '8px 8px 8px 22px',
          border: `0.5px solid ${t.line}`,
        }}>
          <div style={{ flex: 1, fontSize: 15, color: t.inkFaint }}>Tap mic, or type…</div>
          <IconBtn ariaLabel="Type a prompt instead" style={{ color: t.inkDim }} size={36}>
            {Icon.keyboard(20)}
          </IconBtn>
          <IconBtn ariaLabel="Start voice prompt" size={48} style={{
            background: t.accent, color: t.accentInk,
            boxShadow: t.statusDark
              ? '0 0 0 4px rgba(244,241,237,0.08)'
              : '0 4px 14px rgba(0,0,0,0.08)',
          }}>
            {Icon.mic(22)}
          </IconBtn>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 4. Voice Listening
// ─────────────────────────────────────────────────────────────
function ScreenVoiceListening({ theme, anim = true }) {
  const t = THEMES[theme];
  const [step, setStep] = React.useState(0);
  React.useEffect(() => {
    if (!anim) return;
    const i = setInterval(() => setStep((s) => (s + 1) % 60), 80);
    return () => clearInterval(i);
  }, [anim]);
  const transcript = "a fox curled up in tall grass at sunset";
  const heard = transcript.slice(0, Math.min(transcript.length, Math.floor(step * 0.8) + 12));
  const bars = Array.from({ length: 28 }, (_, i) => {
    const phase = (step + i * 3) * 0.15;
    return 0.25 + Math.abs(Math.sin(phase)) * 0.6 + (((i * 137) % 100) / 100) * 0.15;
  });

  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60,
      display: 'flex', flexDirection: 'column', position: 'relative',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', padding: '14px 20px 0' }}>
        <div style={{ fontSize: 13, color: t.inkDim, fontFamily: MONO, letterSpacing: 0.4 }}>
          LISTENING
        </div>
        <IconBtn ariaLabel="Cancel voice prompt" size={34} style={{ background: t.surface, color: t.ink }}>
          {Icon.close(18)}
        </IconBtn>
      </div>

      <div style={{ flex: 1, padding: '0 28px',
        display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
        <div aria-live="polite" style={{
          fontFamily: t.titleFont, fontSize: 26, lineHeight: 1.25,
          letterSpacing: -0.4, fontWeight: 500, minHeight: 130,
        }}>
          <span>"{heard}</span>
          <span aria-hidden="true" style={{
            display: 'inline-block', width: 2, height: 22, background: t.accent,
            marginLeft: 2, verticalAlign: '-3px',
            opacity: step % 8 < 4 ? 1 : 0.2,
          }} />
        </div>
      </div>

      <div style={{ padding: '0 20px 40px' }}>
        <div style={{
          height: 96, borderRadius: 48,
          background: t.surface,
          display: 'flex', alignItems: 'center', justifyContent: 'space-between',
          padding: '0 16px', border: `0.5px solid ${t.line}`,
        }}>
          <IconBtn ariaLabel="Switch to keyboard input" size={56} style={{ opacity: 0.6 }}>
            {Icon.keyboard(22)}
          </IconBtn>
          <div aria-hidden="true" style={{
            flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center',
            gap: 3, height: 56,
          }}>
            {bars.map((b, i) => (
              <div key={i} style={{
                width: 3, height: `${b * 100}%`, minHeight: 3, borderRadius: 2,
                background: t.accent,
                opacity: 0.55 + Math.sin((step + i * 2) * 0.2) * 0.45,
              }} />
            ))}
          </div>
          <IconBtn ariaLabel="Stop listening and generate" size={56} style={{
            background: t.accent, color: t.accentInk,
          }}>
            <div style={{ width: 16, height: 16, background: t.accentInk, borderRadius: 3 }} />
          </IconBtn>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 5. Generating
// ─────────────────────────────────────────────────────────────
function ScreenGenerating({ theme, anim = true }) {
  const t = THEMES[theme];
  const [step, setStep] = React.useState(0);
  React.useEffect(() => {
    if (!anim) return;
    const i = setInterval(() => setStep((s) => s + 1), 60);
    return () => clearInterval(i);
  }, [anim]);
  const breath = 0.5 + Math.sin(step * 0.07) * 0.5;
  const hue = 22 + step * 0.6;

  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60,
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: '14px 20px 0' }}>
        <button type="button" aria-label="Close" style={{
          fontSize: 15, color: t.inkDim, background: 'transparent',
          border: 'none', cursor: 'pointer', padding: 0,
          display: 'flex', alignItems: 'center', gap: 4,
        }}>{Icon.close(20)}</button>
        <div style={{ fontSize: 13, color: t.inkDim, fontFamily: MONO }}>~7s</div>
      </div>

      <div style={{ padding: '24px 28px 16px' }}>
        <div style={{
          fontSize: 11, letterSpacing: 0.6, textTransform: 'uppercase',
          color: t.inkFaint, fontFamily: MONO, marginBottom: 8,
        }}>You asked for</div>
        <div style={{ fontFamily: t.titleFont, fontSize: 22, lineHeight: 1.25,
          letterSpacing: -0.3, fontWeight: 500 }}>
          "a fox curled up in tall grass at sunset"
        </div>
      </div>

      <div role="status" aria-live="polite" aria-label="Generating image, about seven seconds remaining"
        style={{ flex: 1, padding: '8px 28px 28px',
        display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{
          width: '100%', aspectRatio: '1', borderRadius: 24,
          position: 'relative', overflow: 'hidden',
          background: `radial-gradient(circle at ${50 + Math.sin(step * 0.04) * 20}% ${50 + Math.cos(step * 0.05) * 20}%,
            oklch(0.72 0.11 ${hue}) 0%,
            oklch(0.55 0.13 ${hue + 60}) 40%,
            oklch(0.30 0.08 ${hue + 120}) 100%)`,
          boxShadow: t.statusDark
            ? '0 20px 60px rgba(0,0,0,0.5)'
            : '0 20px 50px rgba(0,0,0,0.10)',
          transform: `scale(${0.99 + breath * 0.015})`,
          transition: 'transform 60ms linear',
        }}>
          <div style={{ position: 'absolute', inset: '-10%',
            background: `radial-gradient(50% 40% at ${30 + Math.sin(step * 0.03) * 30}% 50%, rgba(255,255,255,0.4) 0%, transparent 60%)`,
            mixBlendMode: 'overlay', filter: 'blur(20px)' }} />
          <div style={{ position: 'absolute', inset: '-10%',
            background: `radial-gradient(40% 30% at ${70 - Math.cos(step * 0.04) * 20}% ${30 + Math.sin(step * 0.06) * 30}%, rgba(0,0,0,0.25) 0%, transparent 60%)`,
            mixBlendMode: 'multiply', filter: 'blur(28px)' }} />
          <div style={{ position: 'absolute', inset: 0,
            background: 'repeating-linear-gradient(0deg, rgba(0,0,0,0.04) 0 1px, transparent 1px 2px)',
            mixBlendMode: 'overlay' }} />
          <div style={{ position: 'absolute', inset: 0,
            display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            <div style={{
              padding: '8px 14px', borderRadius: 999,
              background: 'rgba(0,0,0,0.35)', backdropFilter: 'blur(10px)',
              fontFamily: MONO, fontSize: 11, color: 'rgba(255,255,255,0.95)',
              letterSpacing: 0.6, textTransform: 'uppercase',
              display: 'flex', alignItems: 'center', gap: 8,
            }}>
              <div style={{ width: 6, height: 6, borderRadius: 3, background: '#fff',
                opacity: 0.4 + breath * 0.6 }} />
              Making
            </div>
          </div>
        </div>
      </div>

      <div style={{ padding: '0 20px 40px', textAlign: 'center' }}>
        <button type="button" aria-label="Cancel generation" style={{
          background: 'transparent', border: 'none',
          color: t.inkDim, fontSize: 15, padding: '8px 16px', cursor: 'pointer',
        }}>Cancel</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 6. Result — reworked hierarchy: iteration first, save secondary
// ─────────────────────────────────────────────────────────────
function ScreenResult({ theme }) {
  const t = THEMES[theme];
  const prompt = "a fox curled up in tall grass at sunset";
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60,
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: '14px 20px 0' }}>
        <button type="button" aria-label="Close and return to library" style={{
          fontSize: 15, color: t.inkDim, background: 'transparent',
          border: 'none', cursor: 'pointer', padding: 0,
          display: 'flex', alignItems: 'center', gap: 4,
        }}>{Icon.close(20)}</button>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6,
          fontSize: 11, fontFamily: MONO, color: t.inkFaint, letterSpacing: 0.5 }}>
          {Icon.shield(13)} ON DEVICE
        </div>
      </div>

      <div style={{ padding: '20px 28px 14px' }}>
        <div style={{ fontFamily: t.titleFont, fontSize: 20, lineHeight: 1.25,
          letterSpacing: -0.2, fontWeight: 500 }}>
          "{prompt}"
        </div>
        <div style={{ fontSize: 11, color: t.inkFaint, fontFamily: MONO,
          letterSpacing: 0.5, marginTop: 6 }}>
          Saved to LocalImage library · 768²
        </div>
      </div>

      <div style={{ flex: 1, padding: '4px 28px 16px',
        display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <div style={{
          width: '100%', aspectRatio: '1', borderRadius: 24,
          overflow: 'hidden', position: 'relative',
          boxShadow: t.statusDark
            ? '0 20px 60px rgba(0,0,0,0.5)'
            : '0 20px 50px rgba(0,0,0,0.12)',
        }}>
          <ImgPlaceholder seed={3} theme={t} rounded={24}
            style={{ width: '100%', height: '100%' }}
            alt={`Generated image for the prompt: ${prompt}`} />
        </div>
      </div>

      {/* Reworked hierarchy:
          Primary (full-width pair): Try again + Refine — the iteration loop.
          Secondary row: Save to Photos · Share — auto-saved already, this is for camera-roll/share. */}
      <div style={{ padding: '8px 20px 40px' }}>
        <div style={{ display: 'flex', gap: 10, marginBottom: 10 }}>
          <button type="button" aria-label="Try again with the same prompt" style={{
            flex: 1, height: 56, borderRadius: 16, border: 'none',
            background: t.accent, color: t.accentInk,
            fontFamily: LI_FONT, fontSize: 16, fontWeight: 600, letterSpacing: -0.2,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            cursor: 'pointer',
          }}>
            {Icon.refresh(20)} Try again
          </button>
          <button type="button" aria-label="Refine and edit the prompt" style={{
            flex: 1, height: 56, borderRadius: 16, border: 'none',
            background: t.accent, color: t.accentInk,
            fontFamily: LI_FONT, fontSize: 16, fontWeight: 600, letterSpacing: -0.2,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            cursor: 'pointer', opacity: 0.86,
          }}>
            {Icon.edit(20)} Refine
          </button>
        </div>
        <div style={{ display: 'flex', gap: 10 }}>
          <button type="button" aria-label="Save to your Photos" style={{
            flex: 1, height: 44, borderRadius: 12, border: `0.5px solid ${t.line}`,
            background: 'transparent', color: t.ink,
            fontFamily: LI_FONT, fontSize: 14, fontWeight: 500,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
            cursor: 'pointer',
          }}>
            {Icon.save(16)} Save to Photos
          </button>
          <button type="button" aria-label="Share image" style={{
            flex: 1, height: 44, borderRadius: 12, border: `0.5px solid ${t.line}`,
            background: 'transparent', color: t.ink,
            fontFamily: LI_FONT, fontSize: 14, fontWeight: 500,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
            cursor: 'pointer',
          }}>
            {Icon.share(16)} Share
          </button>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 7. History — Chat & Feed (image-first)
// ─────────────────────────────────────────────────────────────
function HistoryShell({ theme, children }) {
  const t = THEMES[theme];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60,
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        padding: '14px 20px 16px' }}>
        <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.2 }}>LocalImage</div>
        <IconBtn ariaLabel="Settings" size={34} style={{ background: t.surface, color: t.ink }}>
          {Icon.cog(18)}
        </IconBtn>
      </div>
      {children}
      <div style={{ padding: '12px 20px 40px' }}>
        <div style={{
          display: 'flex', alignItems: 'center', gap: 10,
          background: t.surface, borderRadius: 999,
          padding: '6px 6px 6px 18px', border: `0.5px solid ${t.line}`,
        }}>
          <div style={{ flex: 1, fontSize: 14, color: t.inkFaint }}>Describe an image…</div>
          <IconBtn ariaLabel="Start voice prompt" size={40} style={{ background: t.accent, color: t.accentInk }}>
            {Icon.mic(20)}
          </IconBtn>
        </div>
      </div>
    </div>
  );
}

function ScreenHistoryChat({ theme }) {
  const t = THEMES[theme];
  const items = [
    { prompt: 'a wolf in a snowstorm', seed: 0, time: 'Just now' },
    { prompt: 'porcelain teapot, studio light', seed: 1, time: '2 min ago' },
    { prompt: 'kid astronaut, polaroid', seed: 2, time: 'Yesterday' },
  ];
  return (
    <HistoryShell theme={theme}>
      <div style={{ flex: 1, overflow: 'hidden', padding: '8px 20px 0',
        display: 'flex', flexDirection: 'column', gap: 28 }}>
        {items.map((it, i) => (
          <div key={i}>
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 8 }}>
              <div style={{ maxWidth: '78%', padding: '10px 14px', borderRadius: 18,
                background: t.accent, color: t.accentInk,
                fontSize: 14.5, lineHeight: 1.35 }}>{it.prompt}</div>
            </div>
            <div style={{ width: '78%', aspectRatio: '1', borderRadius: 18, overflow: 'hidden',
              boxShadow: '0 4px 16px rgba(0,0,0,0.06)' }}>
              <ImgPlaceholder seed={it.seed} theme={t} rounded={18}
                style={{ width: '100%', height: '100%' }}
                alt={`Generated image for: ${it.prompt}`} />
            </div>
            <div style={{ fontSize: 11, color: t.inkFaint, marginTop: 6,
              fontFamily: MONO, letterSpacing: 0.3 }}>{it.time}</div>
          </div>
        ))}
      </div>
    </HistoryShell>
  );
}

function ScreenHistoryFeed({ theme }) {
  const t = THEMES[theme];
  const items = [
    { prompt: 'a wolf in a snowstorm', seed: 0, time: 'Just now' },
    { prompt: 'porcelain teapot, studio light', seed: 1, time: '2 min ago' },
    { prompt: 'kid astronaut, polaroid', seed: 2, time: 'Yesterday' },
  ];
  return (
    <HistoryShell theme={theme}>
      <div style={{ flex: 1, overflow: 'hidden', padding: '0 20px',
        display: 'flex', flexDirection: 'column', gap: 28 }}>
        {items.map((it, i) => (
          <div key={i}>
            <div style={{ width: '100%', aspectRatio: '1', borderRadius: 20, overflow: 'hidden',
              boxShadow: t.statusDark
                ? '0 8px 24px rgba(0,0,0,0.4)'
                : '0 8px 24px rgba(0,0,0,0.08)' }}>
              <ImgPlaceholder seed={it.seed} theme={t} rounded={20}
                style={{ width: '100%', height: '100%' }}
                alt={`Generated image for: ${it.prompt}`} />
            </div>
            <div style={{ fontFamily: t.titleFont, fontSize: 17, lineHeight: 1.3,
              letterSpacing: -0.2, fontWeight: 500, marginTop: 12, color: t.ink }}>"{it.prompt}"</div>
            <div style={{ fontSize: 11, color: t.inkFaint, marginTop: 4,
              fontFamily: MONO, letterSpacing: 0.3 }}>{it.time}</div>
          </div>
        ))}
      </div>
    </HistoryShell>
  );
}

// ─────────────────────────────────────────────────────────────
// 8. ERROR STATES
// ─────────────────────────────────────────────────────────────

function ErrorShell({ theme, kind, title, body, primary, secondary, icon, iconColor }) {
  const t = THEMES[theme];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, paddingTop: 60,
      display: 'flex', flexDirection: 'column',
    }}>
      <div style={{ padding: '14px 20px 0', display: 'flex', justifyContent: 'flex-end' }}>
        <IconBtn ariaLabel="Close" size={34} style={{ background: t.surface, color: t.ink }}>
          {Icon.close(18)}
        </IconBtn>
      </div>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column',
        alignItems: 'flex-start', justifyContent: 'center', padding: '0 28px' }}>
        <div style={{
          width: 56, height: 56, borderRadius: 16, background: t.surface,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: iconColor || t.danger, marginBottom: 22,
          border: `0.5px solid ${t.line}`,
        }}>{icon}</div>
        <div style={{ fontSize: 11, letterSpacing: 0.6, textTransform: 'uppercase',
          color: t.inkFaint, fontFamily: MONO, marginBottom: 8 }}>{kind}</div>
        <div style={{ fontFamily: t.titleFont, fontSize: 26, lineHeight: 1.15,
          letterSpacing: -0.5, fontWeight: 500, marginBottom: 10 }}>
          {title}
        </div>
        <div style={{ fontSize: 14.5, lineHeight: 1.5, color: t.inkDim, maxWidth: 320 }}>
          {body}
        </div>
      </div>
      <div style={{ padding: '0 20px 40px', display: 'flex', flexDirection: 'column', gap: 8 }}>
        <button type="button" aria-label={primary.label} style={{
          width: '100%', height: 54, borderRadius: 16, border: 'none',
          background: t.accent, color: t.accentInk,
          fontFamily: LI_FONT, fontSize: 16, fontWeight: 600, cursor: 'pointer',
        }}>{primary.label}</button>
        {secondary && (
          <button type="button" aria-label={secondary.label} style={{
            width: '100%', height: 44, borderRadius: 12, border: 'none',
            background: 'transparent', color: t.inkDim,
            fontFamily: LI_FONT, fontSize: 14, fontWeight: 500, cursor: 'pointer',
          }}>{secondary.label}</button>
        )}
      </div>
    </div>
  );
}

function ScreenErrorDownload({ theme }) {
  return (
    <ErrorShell
      theme={theme}
      kind="DOWNLOAD INTERRUPTED"
      title="Couldn't finish the download"
      body="The connection dropped at 64%. We've saved your progress — picking up where you left off should only take about a minute on Wi-Fi."
      icon={Icon.warn(28)}
      primary={{ label: 'Resume from 64%' }}
      secondary={{ label: 'Try again later' }}
    />
  );
}

function ScreenErrorGeneration({ theme }) {
  return (
    <ErrorShell
      theme={theme}
      kind="COULDN'T MAKE THIS ONE"
      title="Something went sideways"
      body="The model ran out of memory part-way through. Closing other apps usually fixes it. Your prompt is still saved."
      icon={Icon.warn(28)}
      primary={{ label: 'Try again' }}
      secondary={{ label: 'Edit prompt' }}
    />
  );
}

function ScreenErrorBlocked({ theme }) {
  const t = THEMES[theme];
  return (
    <ErrorShell
      theme={theme}
      kind="THIS PROMPT WAS BLOCKED"
      title="LocalImage skipped this one"
      body="A small set of prompts is filtered to keep the app safe and welcoming. Your prompt isn't shared anywhere — it stayed on your device."
      iconColor={t.inkDim}
      icon={Icon.lock(24)}
      primary={{ label: 'Edit prompt' }}
      secondary={{ label: 'Learn more' }}
    />
  );
}

// ─────────────────────────────────────────────────────────────
// 9. APP ICON EXPLORATIONS
// ─────────────────────────────────────────────────────────────
function AppIcon({ size = 120, variant }) {
  const r = size * 0.225; // iOS squircle radius
  const common = {
    width: size, height: size, borderRadius: r,
    overflow: 'hidden', position: 'relative',
    boxShadow: '0 8px 24px rgba(0,0,0,0.18), inset 0 0 0 0.5px rgba(255,255,255,0.4)',
    flexShrink: 0,
  };
  if (variant === 'aperture') {
    return (
      <div style={{ ...common, background: '#1C1814' }}>
        <div style={{
          position: 'absolute', inset: '20%',
          borderRadius: '50%',
          background: 'conic-gradient(from 0deg, oklch(0.72 0.16 28), oklch(0.55 0.18 60), oklch(0.45 0.16 220), oklch(0.55 0.16 320), oklch(0.72 0.16 28))',
          filter: 'blur(2px)',
        }} />
        <div style={{
          position: 'absolute', inset: '32%', borderRadius: '50%',
          background: '#FBF8F2',
        }} />
      </div>
    );
  }
  if (variant === 'wordmark') {
    return (
      <div style={{ ...common,
        background: 'linear-gradient(135deg, #FBF8F2 0%, #EBE6DB 100%)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <div style={{
          fontFamily: '"Tiempos Headline", Georgia, serif',
          fontSize: size * 0.5, fontWeight: 500, letterSpacing: -2,
          color: '#1C1814', lineHeight: 1,
        }}>Li</div>
      </div>
    );
  }
  if (variant === 'tile') {
    return (
      <div style={{ ...common, background: '#0E0D11' }}>
        <div style={{
          position: 'absolute', left: '50%', top: '50%',
          transform: 'translate(-50%, -50%)',
          width: '52%', height: '52%', borderRadius: r * 0.6,
          background: 'linear-gradient(135deg, oklch(0.72 0.16 28) 0%, oklch(0.45 0.18 320) 100%)',
        }} />
        <div style={{
          position: 'absolute', inset: 0,
          background: `repeating-linear-gradient(135deg, rgba(255,255,255,0.04) 0 ${size*0.04}px, transparent ${size*0.04}px ${size*0.12}px)`,
        }} />
      </div>
    );
  }
  if (variant === 'lens') {
    return (
      <div style={{ ...common,
        background: 'radial-gradient(circle at 30% 25%, #F4F1EB 0%, #C9C2B2 50%, #6E6557 100%)',
      }}>
        <div style={{
          position: 'absolute', inset: '18%', borderRadius: '50%',
          background: 'radial-gradient(circle at 30% 25%, #fff 0%, oklch(0.45 0.16 240) 35%, #0E0D11 90%)',
          boxShadow: 'inset 0 0 0 2px rgba(0,0,0,0.3)',
        }} />
        <div style={{
          position: 'absolute', inset: '28%', borderRadius: '50%',
          background: 'radial-gradient(circle at 30% 25%, oklch(0.65 0.20 28) 0%, oklch(0.30 0.15 30) 70%)',
        }} />
        <div style={{
          position: 'absolute', left: '32%', top: '28%',
          width: '14%', height: '10%', borderRadius: '50%',
          background: 'rgba(255,255,255,0.7)', filter: 'blur(1px)',
        }} />
      </div>
    );
  }
  if (variant === 'spark') {
    return (
      <div style={{ ...common,
        background: 'linear-gradient(180deg, #F4F1EB 0%, #DBD4C3 100%)',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        <svg width={size * 0.6} height={size * 0.6} viewBox="0 0 24 24" fill="#1C1814" aria-hidden="true">
          <path d="M12 2 L13.5 9 L21 10.5 L13.5 12 L12 19 L10.5 12 L3 10.5 L10.5 9 Z"/>
        </svg>
      </div>
    );
  }
  if (variant === 'window') {
    return (
      <div style={{ ...common,
        background: 'linear-gradient(180deg, oklch(0.72 0.10 60) 0%, oklch(0.42 0.10 28) 60%, oklch(0.22 0.06 280) 100%)',
      }}>
        {/* horizon */}
        <div style={{
          position: 'absolute', left: 0, right: 0, top: '60%',
          height: 1, background: 'rgba(0,0,0,0.25)',
        }} />
        {/* sun */}
        <div style={{
          position: 'absolute', left: '50%', top: '50%',
          transform: 'translate(-50%, -50%)',
          width: '34%', height: '34%', borderRadius: '50%',
          background: 'radial-gradient(circle, oklch(0.92 0.10 80) 0%, oklch(0.78 0.16 50) 70%)',
          filter: 'blur(0.5px)',
        }} />
        {/* frame */}
        <div style={{
          position: 'absolute', inset: '12%', borderRadius: r * 0.5,
          border: '2px solid rgba(255,255,255,0.6)',
          pointerEvents: 'none',
        }} />
      </div>
    );
  }
  return null;
}

function ScreenAppIcons() {
  const variants = [
    { id: 'aperture', name: 'Aperture', tag: 'Camera lens, prism' },
    { id: 'wordmark', name: 'Tiempos Li', tag: 'Quiet, editorial' },
    { id: 'tile', name: 'Tile', tag: 'Bold, dark, gradient' },
    { id: 'lens', name: 'Glass lens', tag: 'Real-world, tactile' },
    { id: 'spark', name: 'Spark', tag: 'Generation as making' },
    { id: 'window', name: 'Window', tag: '"See" something' },
  ];
  return (
    <div style={{
      width: '100%', height: '100%',
      background: '#FBF8F2', color: '#1C1814',
      fontFamily: LI_FONT, padding: '40px 32px',
      overflow: 'auto',
    }}>
      <div style={{
        fontFamily: '"Tiempos Headline", Georgia, serif',
        fontSize: 24, fontWeight: 500, letterSpacing: -0.4,
        marginBottom: 6,
      }}>App icon — six directions</div>
      <div style={{ fontSize: 12.5, color: 'rgba(28,24,20,0.55)', marginBottom: 28 }}>
        Springboard size + a smaller in-context size. None of these try to depict AI directly — that aesthetic is already played out.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 28 }}>
        {variants.map((v) => (
          <div key={v.id}>
            <div style={{ display: 'flex', alignItems: 'flex-end', gap: 12, marginBottom: 10 }}>
              <AppIcon size={108} variant={v.id} />
              <AppIcon size={48} variant={v.id} />
            </div>
            <div style={{ fontSize: 14, fontWeight: 600, letterSpacing: -0.2 }}>{v.name}</div>
            <div style={{ fontSize: 12, color: 'rgba(28,24,20,0.55)' }}>{v.tag}</div>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 32, padding: '16px 18px', borderRadius: 14,
        background: '#F4F1EB', fontSize: 12.5, lineHeight: 1.5,
        color: 'rgba(28,24,20,0.7)' }}>
        <strong style={{ color: 'rgba(28,24,20,0.9)' }}>Recommendation:</strong> "Glass lens" or "Window".
        Both communicate <em>seeing</em> rather than <em>generating</em> — which is closer to the user's mental model. Aperture also strong, more tech-forward.
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 10. Action sheet — what's behind the "..." in history
// ─────────────────────────────────────────────────────────────
function ScreenActionSheet({ theme }) {
  const t = THEMES[theme];
  // Render the feed dimmed underneath, then a bottom sheet.
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      <div style={{ position: 'absolute', inset: 0, filter: 'blur(2px) brightness(0.85)' }}>
        <ScreenHistoryFeed theme={theme} />
      </div>
      <div style={{ position: 'absolute', inset: 0,
        background: t.statusDark ? 'rgba(0,0,0,0.45)' : 'rgba(0,0,0,0.25)' }} />
      <div style={{
        position: 'absolute', left: 8, right: 8, bottom: 8,
        background: t.surface, borderRadius: 20, overflow: 'hidden',
        boxShadow: '0 -8px 40px rgba(0,0,0,0.18)',
        border: `0.5px solid ${t.line}`,
      }}>
        <div style={{ padding: '12px 18px 6px',
          fontFamily: MONO, fontSize: 10, letterSpacing: 0.6,
          color: t.inkFaint, textTransform: 'uppercase' }}>
          "kid astronaut, polaroid"
        </div>
        {[
          { label: 'Use this prompt again', sub: 'Drops it into the composer', group: 'make' },
          { label: 'Refine prompt', sub: 'Edit, then generate', group: 'make' },
          { label: 'Make a variation', sub: 'Same prompt, new seed', group: 'make' },
          { label: 'Save to Photos', sub: 'Adds a 768² PNG to your camera roll', group: 'send' },
          { label: 'Share…', sub: 'Choose an app — leaves the device only when you pick one', group: 'send' },
          { label: 'Copy prompt as text', sub: '', group: 'send' },
          { label: 'Delete', sub: 'Removes from library', destructive: true, group: 'destroy' },
        ].map((row, i, arr) => {
          const prev = arr[i - 1];
          const groupBreak = prev && prev.group !== row.group;
          return (
            <React.Fragment key={i}>
              {groupBreak && (
                <div style={{ height: 6, background: t.bg }} />
              )}
              <button type="button" aria-label={row.label} style={{
                display: 'flex', flexDirection: 'column', alignItems: 'flex-start',
                width: '100%', padding: '13px 18px', gap: 2,
                background: 'transparent', border: 'none', cursor: 'pointer',
                borderTop: (i === 0 || groupBreak) ? 'none' : `0.5px solid ${t.line}`,
                textAlign: 'left',
              }}>
                <span style={{ fontSize: 16, fontWeight: 500, fontFamily: LI_FONT,
                  color: row.destructive ? t.danger : t.ink }}>{row.label}</span>
                {row.sub && <span style={{ fontSize: 12, color: t.inkDim, lineHeight: 1.35 }}>{row.sub}</span>}
              </button>
            </React.Fragment>
          );
        })}
        <button type="button" aria-label="Cancel" style={{
          width: '100%', padding: '14px', fontSize: 16, fontWeight: 600,
          background: 'transparent', border: 'none', cursor: 'pointer',
          color: t.inkDim, fontFamily: LI_FONT,
          borderTop: `0.5px solid ${t.line}`,
        }}>Cancel</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 11. iPad layout — split view, library left, focused result right
// ─────────────────────────────────────────────────────────────
function ScreenIPad({ theme }) {
  const t = THEMES[theme];
  const items = [
    { prompt: 'a wolf in a snowstorm', seed: 0, time: 'Just now' },
    { prompt: 'porcelain teapot, studio light', seed: 1, time: '2 min' },
    { prompt: 'kid astronaut, polaroid', seed: 2, time: 'Yesterday' },
    { prompt: 'hummingbird mid-flight', seed: 3, time: 'Yesterday' },
    { prompt: 'cathedral of moss', seed: 4, time: '2 d' },
    { prompt: 'ramen shop at midnight', seed: 5, time: '3 d' },
  ];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, display: 'flex', overflow: 'hidden',
    }}>
      {/* sidebar */}
      <div style={{
        width: 280, borderRight: `0.5px solid ${t.line}`,
        display: 'flex', flexDirection: 'column', padding: '20px 16px',
        background: t.surface,
      }}>
        <div style={{ fontSize: 17, fontWeight: 600, letterSpacing: -0.2,
          padding: '4px 8px 16px' }}>LocalImage</div>
        <button type="button" aria-label="New prompt" style={{
          padding: '10px 14px', background: t.accent, color: t.accentInk,
          border: 'none', borderRadius: 12, cursor: 'pointer',
          fontFamily: LI_FONT, fontSize: 14, fontWeight: 600,
          textAlign: 'left', marginBottom: 16,
        }}>+ New prompt</button>
        <div style={{ fontSize: 10, fontFamily: MONO, letterSpacing: 0.6,
          color: t.inkFaint, padding: '8px 8px 8px', textTransform: 'uppercase' }}>Library</div>
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 4, overflow: 'hidden' }}>
          {items.map((it, i) => (
            <div key={i} style={{
              display: 'flex', gap: 10, padding: '6px 8px', borderRadius: 10,
              background: i === 2 ? t.surfaceAlt : 'transparent',
              alignItems: 'center', cursor: 'pointer',
            }}>
              <div style={{ width: 36, height: 36, borderRadius: 7, overflow: 'hidden', flexShrink: 0 }}>
                <ImgPlaceholder seed={it.seed} theme={t} rounded={7}
                  style={{ width: '100%', height: '100%' }} alt={it.prompt} />
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontSize: 13, color: t.ink, lineHeight: 1.3,
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {it.prompt}
                </div>
                <div style={{ fontSize: 10, color: t.inkFaint, fontFamily: MONO, letterSpacing: 0.3 }}>
                  {it.time}
                </div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* main canvas */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between',
          alignItems: 'center', padding: '20px 32px 0' }}>
          <div style={{ fontFamily: t.titleFont, fontSize: 22, fontWeight: 500,
            letterSpacing: -0.3 }}>"kid astronaut, polaroid"</div>
          <div style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6,
              fontSize: 11, fontFamily: MONO, color: t.inkFaint, letterSpacing: 0.5,
              marginRight: 4 }}>
              {Icon.shield(13)} ON DEVICE
            </div>
            <button type="button" aria-label="Save to Photos" style={{
              padding: '8px 14px', borderRadius: 10, fontSize: 13, fontWeight: 500,
              background: t.surface, border: `0.5px solid ${t.line}`, color: t.ink,
              cursor: 'pointer', fontFamily: LI_FONT, display: 'flex', alignItems: 'center', gap: 6,
            }}>{Icon.save(15)} Save</button>
            <button type="button" aria-label="Share image" style={{
              padding: '8px 14px', borderRadius: 10, fontSize: 13, fontWeight: 500,
              background: t.surface, border: `0.5px solid ${t.line}`, color: t.ink,
              cursor: 'pointer', fontFamily: LI_FONT, display: 'flex', alignItems: 'center', gap: 6,
            }}>{Icon.share(15)} Share</button>
          </div>
        </div>

        <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: '24px 32px' }}>
          <div style={{ width: 540, height: 540, borderRadius: 24, overflow: 'hidden',
            boxShadow: t.statusDark
              ? '0 30px 80px rgba(0,0,0,0.5)'
              : '0 30px 60px rgba(0,0,0,0.12)' }}>
            <ImgPlaceholder seed={2} theme={t} rounded={24}
              style={{ width: '100%', height: '100%' }} alt="kid astronaut, polaroid" />
          </div>
        </div>

        <div style={{ padding: '0 32px 32px' }}>
          <div style={{ display: 'flex', gap: 10, marginBottom: 10 }}>
            <button type="button" style={{
              flex: 1, height: 52, borderRadius: 14, border: 'none',
              background: t.accent, color: t.accentInk,
              fontFamily: LI_FONT, fontSize: 15, fontWeight: 600, cursor: 'pointer',
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            }}>{Icon.refresh(18)} Try again</button>
            <button type="button" style={{
              flex: 1, height: 52, borderRadius: 14, border: 'none',
              background: t.accent, color: t.accentInk,
              fontFamily: LI_FONT, fontSize: 15, fontWeight: 600, cursor: 'pointer', opacity: 0.86,
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            }}>{Icon.edit(18)} Refine</button>
          </div>
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10,
            background: t.surface, borderRadius: 999, padding: '6px 6px 6px 18px',
            border: `0.5px solid ${t.line}`,
          }}>
            <div style={{ flex: 1, fontSize: 14, color: t.inkFaint }}>Describe an image…</div>
            <IconBtn ariaLabel="Start voice prompt" size={40}
              style={{ background: t.accent, color: t.accentInk }}>{Icon.mic(20)}</IconBtn>
          </div>
        </div>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────
// 12. macOS layout — window chrome + same split, denser
// ─────────────────────────────────────────────────────────────
function ScreenMac({ theme }) {
  const t = THEMES[theme];
  const items = [
    { prompt: 'a wolf in a snowstorm', seed: 0, time: 'Just now' },
    { prompt: 'porcelain teapot, studio light', seed: 1, time: '2 min' },
    { prompt: 'kid astronaut, polaroid', seed: 2, time: 'Yesterday' },
    { prompt: 'hummingbird mid-flight', seed: 3, time: 'Yesterday' },
  ];
  return (
    <div style={{
      width: '100%', height: '100%', background: t.bg, color: t.ink,
      fontFamily: LI_FONT, display: 'flex', flexDirection: 'column', overflow: 'hidden',
    }}>
      {/* title bar */}
      <div style={{
        height: 38, display: 'flex', alignItems: 'center',
        padding: '0 14px', borderBottom: `0.5px solid ${t.line}`,
        background: t.surface, gap: 8,
      }}>
        <div style={{ display: 'flex', gap: 6 }}>
          <div style={{ width: 12, height: 12, borderRadius: 6, background: '#FF5F57' }} />
          <div style={{ width: 12, height: 12, borderRadius: 6, background: '#FEBC2E' }} />
          <div style={{ width: 12, height: 12, borderRadius: 6, background: '#28C840' }} />
        </div>
        <div style={{ flex: 1, textAlign: 'center', fontSize: 12, color: t.inkDim, fontWeight: 500 }}>
          LocalImage
        </div>
        <div style={{ width: 54 }} />
      </div>

      <div style={{ flex: 1, display: 'flex', overflow: 'hidden' }}>
        {/* sidebar */}
        <div style={{
          width: 220, borderRight: `0.5px solid ${t.line}`, padding: '14px 10px',
          background: t.surface, display: 'flex', flexDirection: 'column',
        }}>
          <button type="button" style={{
            padding: '8px 12px', background: t.accent, color: t.accentInk,
            border: 'none', borderRadius: 8, cursor: 'pointer',
            fontFamily: LI_FONT, fontSize: 12, fontWeight: 600,
            textAlign: 'left', marginBottom: 12,
          }}>+ New prompt  ⌘N</button>
          <div style={{ fontSize: 9.5, fontFamily: MONO, letterSpacing: 0.6,
            color: t.inkFaint, padding: '6px 8px', textTransform: 'uppercase' }}>Library</div>
          <div style={{ flex: 1, display: 'flex', flexDirection: 'column', gap: 2, overflow: 'hidden' }}>
            {items.map((it, i) => (
              <div key={i} style={{
                display: 'flex', gap: 8, padding: '5px 8px', borderRadius: 6,
                background: i === 2 ? t.surfaceAlt : 'transparent',
                alignItems: 'center', cursor: 'pointer',
              }}>
                <div style={{ width: 22, height: 22, borderRadius: 4, overflow: 'hidden', flexShrink: 0 }}>
                  <ImgPlaceholder seed={it.seed} theme={t} rounded={4}
                    style={{ width: '100%', height: '100%' }} alt={it.prompt} />
                </div>
                <div style={{ flex: 1, fontSize: 12, lineHeight: 1.3,
                  whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                  {it.prompt}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* main */}
        <div style={{ flex: 1, display: 'flex', flexDirection: 'column' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between',
            alignItems: 'center', padding: '14px 20px', borderBottom: `0.5px solid ${t.line}` }}>
            <div style={{ fontFamily: t.titleFont, fontSize: 16, fontWeight: 500,
              letterSpacing: -0.2 }}>"kid astronaut, polaroid"</div>
            <div style={{ display: 'flex', gap: 6 }}>
              <button type="button" style={{
                padding: '5px 10px', borderRadius: 6, fontSize: 11, fontWeight: 500,
                background: 'transparent', border: `0.5px solid ${t.line}`, color: t.ink,
                cursor: 'pointer', fontFamily: LI_FONT,
              }}>Save</button>
              <button type="button" style={{
                padding: '5px 10px', borderRadius: 6, fontSize: 11, fontWeight: 500,
                background: 'transparent', border: `0.5px solid ${t.line}`, color: t.ink,
                cursor: 'pointer', fontFamily: LI_FONT,
              }}>Share</button>
            </div>
          </div>

          <div style={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: '20px' }}>
            <div style={{ width: 360, height: 360, borderRadius: 16, overflow: 'hidden',
              boxShadow: t.statusDark ? '0 16px 40px rgba(0,0,0,0.5)' : '0 16px 32px rgba(0,0,0,0.10)' }}>
              <ImgPlaceholder seed={2} theme={t} rounded={16}
                style={{ width: '100%', height: '100%' }} alt="kid astronaut, polaroid" />
            </div>
          </div>

          <div style={{ padding: '0 20px 18px', display: 'flex', flexDirection: 'column', gap: 8 }}>
            <div style={{ display: 'flex', gap: 8 }}>
              <button type="button" style={{
                flex: 1, height: 36, borderRadius: 8, border: 'none',
                background: t.accent, color: t.accentInk,
                fontFamily: LI_FONT, fontSize: 13, fontWeight: 600, cursor: 'pointer',
              }}>↻ Try again</button>
              <button type="button" style={{
                flex: 1, height: 36, borderRadius: 8, border: 'none',
                background: t.accent, color: t.accentInk,
                fontFamily: LI_FONT, fontSize: 13, fontWeight: 600, cursor: 'pointer', opacity: 0.86,
              }}>✎ Refine</button>
            </div>
            <div style={{
              display: 'flex', alignItems: 'center', gap: 8,
              background: t.surface, borderRadius: 8, padding: '6px 6px 6px 12px',
              border: `0.5px solid ${t.line}`,
            }}>
              <div style={{ flex: 1, fontSize: 12.5, color: t.inkFaint }}>Describe an image, or press ⌘⇧D for voice…</div>
              <IconBtn ariaLabel="Start voice prompt" size={26}
                style={{ background: t.accent, color: t.accentInk }}>{Icon.mic(14)}</IconBtn>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

Object.assign(window, {
  THEMES, LI_FONT, MONO,
  ScreenFirstLaunch, ScreenDownload, ScreenEmptyPrompt,
  ScreenVoiceListening, ScreenGenerating, ScreenResult,
  ScreenHistoryChat, ScreenHistoryFeed,
  ScreenErrorDownload, ScreenErrorGeneration, ScreenErrorBlocked,
  ScreenAppIcons, AppIcon,
  ScreenActionSheet, ScreenIPad, ScreenMac,
  ImgPlaceholder, Icon, IconBtn,
});
