// Persona walkthrough — Maya, 34, design-adjacent Canva user
// Renders the 6 main screens at small scale with annotated reactions.

const PERSONA = {
  name: 'Maya Okafor',
  age: 34,
  job: 'Marketing manager · Lagos',
  caption: 'Uses Canva weekly for posts. Has heard of "AI art" but never touched Midjourney. Asked her cousin to install LocalImage for a moodboard for her sister\'s baby shower.',
};

const STEPS = [
  {
    n: '01',
    label: 'First launch',
    Screen: ({ theme, anim }) => <ScreenFirstLaunch theme={theme} anim={anim} />,
    quotes: [
      { mood: 'curious', text: '"Oh — these are nice. So this is what it makes."' },
      { mood: 'reassured', text: '"On my phone. Not the cloud. Good."' },
    ],
    insight: 'The reel does the heavy lifting — she now has a mental picture of what "good output" looks like before she\'s typed anything. Privacy line lands as reassurance, not a sales pitch.',
  },
  {
    n: '02',
    label: 'Installing',
    Screen: ({ theme, anim }) => <ScreenDownload theme={theme} anim={anim} />,
    quotes: [
      { mood: 'patient', text: '"Two minutes is fine. I\'ll come back."' },
      { mood: 'confused', text: '"Wait — is this every time? Oh, says only once."' },
    ],
    insight: 'Critical that "one-time setup" copy sits ABOVE the fold. Without it she would close the app thinking it\'s slow.',
  },
  {
    n: '03',
    label: 'Empty prompt',
    Screen: ({ theme }) => <ScreenEmptyPrompt theme={theme} />,
    quotes: [
      { mood: 'unsure', text: '"What do I even type?"' },
      { mood: 'hopeful', text: '"Oh, the chips. \'PHOTO · a wolf in a snowstorm.\' I can copy that shape."' },
    ],
    insight: 'Suggestion chips do the teaching — she sees that prompts have a STYLE word and a SUBJECT. Without those tags she\'d type "baby shower decorations" and get a flat image.',
  },
  {
    n: '04',
    label: 'Voice',
    Screen: ({ theme, anim }) => <ScreenVoiceListening theme={theme} anim={anim} />,
    quotes: [
      { mood: 'natural', text: '"\'Soft pink balloons floating in a sunny living room\' — talking is easier."' },
    ],
    insight: 'She would not have written that sentence — too many words. Voice unlocks descriptive prompts for non-writers.',
  },
  {
    n: '05',
    label: 'Generating',
    Screen: ({ theme, anim }) => <ScreenGenerating theme={theme} anim={anim} />,
    quotes: [
      { mood: 'patient', text: '"It\'s doing something. Not frozen."' },
    ],
    insight: 'The breathing animation reads as "thinking." She does NOT pull down to refresh, which she would on a stuck spinner.',
  },
  {
    n: '06',
    label: 'Result',
    Screen: ({ theme }) => <ScreenResult theme={theme} />,
    quotes: [
      { mood: 'delighted', text: '"Oh that\'s actually pretty."' },
      { mood: 'iterating', text: '"More gold balloons though. Refine."' },
      { mood: 'wants to share', text: '"I want to send this to Tola — Share."' },
    ],
    insight: 'Try again + Refine being primary catches her actual second move (iterate). Save and Share are visible but quiet — she uses Share when she WANTS to, not because the UI nags her to.',
  },
];

function PersonaWalkthrough() {
  const t = THEMES.paper;
  const W = 720;
  return (
    <div style={{
      width: '100%', minHeight: '100%',
      padding: '40px 36px 56px',
      background: '#FBF8F2',
      fontFamily: '-apple-system, system-ui',
      color: 'rgba(28,24,20,0.95)',
      overflow: 'auto',
    }}>
      {/* Persona card */}
      <div style={{
        display: 'flex', alignItems: 'flex-start', gap: 20,
        padding: '20px 22px', borderRadius: 16,
        background: '#fff', border: '0.5px solid rgba(28,24,20,0.10)',
        marginBottom: 32,
      }}>
        <div style={{
          width: 64, height: 64, borderRadius: 32, flexShrink: 0,
          background: 'linear-gradient(135deg, oklch(0.78 0.06 35), oklch(0.58 0.08 25))',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: '#fff', fontSize: 22, fontFamily: '"Tiempos Headline", Georgia, serif',
          fontWeight: 500, letterSpacing: -0.4,
        }}>MO</div>
        <div style={{ flex: 1 }}>
          <div style={{
            fontFamily: '"Tiempos Headline", Georgia, serif',
            fontSize: 22, fontWeight: 500, letterSpacing: -0.3, marginBottom: 2,
          }}>{PERSONA.name}</div>
          <div style={{ fontSize: 12, fontFamily: MONO, letterSpacing: 0.5,
            color: 'rgba(28,24,20,0.55)', textTransform: 'uppercase', marginBottom: 8 }}>
            {PERSONA.age} · {PERSONA.job}
          </div>
          <div style={{ fontSize: 13.5, lineHeight: 1.55, color: 'rgba(28,24,20,0.75)' }}>
            {PERSONA.caption}
          </div>
        </div>
      </div>

      {/* Walk steps */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 28 }}>
        {STEPS.map((step, i) => (
          <div key={i} style={{
            display: 'flex', gap: 22, alignItems: 'flex-start',
          }}>
            {/* Mini phone — scaled */}
            <div style={{ width: 180, flexShrink: 0 }}>
              <div style={{
                width: 180, height: 391,
                transform: 'scale(1)', transformOrigin: 'top left',
                position: 'relative',
              }}>
                <div style={{
                  position: 'absolute', top: 0, left: 0,
                  width: 402, height: 874,
                  transform: 'scale(0.4477)', transformOrigin: 'top left',
                  background: t.bg, borderRadius: 18, overflow: 'hidden',
                  boxShadow: '0 1px 3px rgba(0,0,0,.08), 0 6px 18px rgba(0,0,0,.06)',
                  border: '0.5px solid rgba(28,24,20,0.08)',
                }}>
                  <step.Screen theme="paper" anim={false} />
                </div>
              </div>
              <div style={{ marginTop: 8, fontFamily: MONO, fontSize: 10,
                letterSpacing: 0.6, color: 'rgba(28,24,20,0.45)',
                textTransform: 'uppercase' }}>
                {step.n} · {step.label}
              </div>
            </div>

            {/* Annotations */}
            <div style={{ flex: 1, paddingTop: 4 }}>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 10, marginBottom: 14 }}>
                {step.quotes.map((q, j) => (
                  <div key={j} style={{
                    display: 'flex', gap: 12, alignItems: 'flex-start',
                  }}>
                    <div style={{
                      fontSize: 9.5, fontFamily: MONO, letterSpacing: 0.5,
                      color: 'rgba(28,24,20,0.45)', textTransform: 'uppercase',
                      paddingTop: 5, minWidth: 92, flexShrink: 0,
                    }}>{q.mood}</div>
                    <div style={{
                      fontFamily: '"Tiempos Headline", Georgia, serif',
                      fontSize: 17, lineHeight: 1.35, fontStyle: 'italic',
                      color: 'rgba(28,24,20,0.92)', letterSpacing: -0.2,
                    }}>{q.text}</div>
                  </div>
                ))}
              </div>
              <div style={{
                fontSize: 12.5, lineHeight: 1.55,
                color: 'rgba(28,24,20,0.65)',
                paddingLeft: 104, paddingTop: 4,
                borderTop: '0.5px solid rgba(28,24,20,0.10)',
                marginTop: 4,
              }}>
                <span style={{ fontFamily: MONO, fontSize: 9.5, letterSpacing: 0.5,
                  color: 'rgba(28,24,20,0.45)', textTransform: 'uppercase',
                  marginRight: 8 }}>Insight</span>
                {step.insight}
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Pull-out: where Maya broke the design */}
      <div style={{
        marginTop: 40, padding: '22px 24px', borderRadius: 16,
        background: 'oklch(0.96 0.025 70)', border: '0.5px solid oklch(0.85 0.04 70)',
      }}>
        <div style={{ fontFamily: '"Tiempos Headline", Georgia, serif',
          fontSize: 18, fontWeight: 500, letterSpacing: -0.2, marginBottom: 10 }}>
          Where Maya broke the design — and what changed
        </div>
        <ul style={{ margin: 0, padding: 0, listStyle: 'none',
          display: 'flex', flexDirection: 'column', gap: 12 }}>
          <li style={{ fontSize: 13, lineHeight: 1.55, color: 'rgba(28,24,20,0.78)' }}>
            <strong>"What's the dots?"</strong> — She hit "⋯" expecting it to scroll the prompt. We were using "⋯" in three different places to mean three different things. Fixed: <code style={{ fontFamily: MONO, fontSize: 12 }}>⋯</code> only ever means "more actions for THIS image." Library and empty-prompt screens now use a settings cog.
          </li>
          <li style={{ fontSize: 13, lineHeight: 1.55, color: 'rgba(28,24,20,0.78)' }}>
            <strong>"Is share safe?"</strong> — The privacy line on first launch made her wary of the Share button later. Fixed: Share button is labelled <code style={{ fontFamily: MONO, fontSize: 12 }}>Share…</code> (the trailing ellipsis is iOS convention for "opens a chooser, you stay in control"), and the action sheet sub-line reads "Choose an app — leaves the device only when you pick one." Privacy promise stays intact; share is reframed as a deliberate, one-tap user choice.
          </li>
          <li style={{ fontSize: 13, lineHeight: 1.55, color: 'rgba(28,24,20,0.78)' }}>
            <strong>"Saved where?"</strong> — She missed the auto-save line. Fixed: micro-line on the Result screen reads "Saved to LocalImage library · 768²" — now larger weight and pinned right below the prompt where her eye lands.
          </li>
          <li style={{ fontSize: 13, lineHeight: 1.55, color: 'rgba(28,24,20,0.78)' }}>
            <strong>"Why three buttons?"</strong> — On iPad she saw Save / Share / ⋯ and froze. Fixed: ⋯ is gone from iPad and Mac — long-press on a library item is the action sheet, top-right is just Save and Share. iPad/Mac now also show the same <strong>ON DEVICE</strong> chip so the privacy promise doesn't disappear on bigger screens.
          </li>
        </ul>
      </div>

      {/* The new ⋯ rule */}
      <div style={{
        marginTop: 24, padding: '20px 22px', borderRadius: 14,
        background: '#fff', border: '0.5px solid rgba(28,24,20,0.10)',
      }}>
        <div style={{ fontFamily: MONO, fontSize: 10, letterSpacing: 0.6,
          color: 'rgba(28,24,20,0.45)', textTransform: 'uppercase', marginBottom: 8 }}>
          The new top-right rule
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18 }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span style={{ fontSize: 18, fontWeight: 700 }}>⚙</span>
              <span style={{ fontSize: 13, fontWeight: 600 }}>Settings cog</span>
            </div>
            <div style={{ fontSize: 12.5, color: 'rgba(28,24,20,0.65)', lineHeight: 1.5 }}>
              Appears on the home/library screen and the empty prompt screen.
              Opens app-level settings: theme, voice locale, content filter, model, about.
            </div>
          </div>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
              <span style={{ fontSize: 18, fontWeight: 700 }}>⋯</span>
              <span style={{ fontSize: 13, fontWeight: 600 }}>Image actions</span>
            </div>
            <div style={{ fontSize: 12.5, color: 'rgba(28,24,20,0.65)', lineHeight: 1.5 }}>
              Only appears next to a single image — long-press in the library, or as
              an affordance in the corner. Always opens the same action sheet.
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

window.PersonaWalkthrough = PersonaWalkthrough;
