# Design Brief: First-Run and Core Generation Experience

**Product**: LocalImage — on-device AI image generation for iPhone, iPad, and macOS  
**Date**: 2026-05-03  
**Status**: For design exploration

---

## Product Vision

LocalImage lets anyone generate an image by describing it in plain language. One prompt, one image, no settings to configure.

The contrast case is Draw Things — technically excellent, but built for people who know what a CFG scale is. LocalImage is built for people who don't. Think Canva: sensible defaults, minimal controls, immediate results.

What makes this distinct from Apple's built-in image tools is that it runs fully on-device and without Apple's content guardrails. Users can generate portraits and lifelike images — the kinds of things Apple's own tools restrict.

---

## Target User

Someone who would describe themselves as a regular iPhone user, not a creative professional. They've used Canva or VSCO. They haven't used Stable Diffusion or Midjourney. They don't know what a prompt is in the AI sense — they just know what they want to see.

---

## The Journey

### 1. First Launch

The app cannot generate images until a model has been downloaded (~1–2GB). This is unavoidable, and the design should make it feel like installation, not loading — a one-time setup that unlocks something.

**What this moment needs to communicate:**
- What's happening and why (a model is being downloaded to your device — so generation stays private and works offline)
- How long it will take (give a real estimate)
- That this only happens once

**The opportunity here:** this is the one moment of genuine anticipation in the app. The designer has latitude to make it feel exciting — to seed the user's imagination for what comes next. Example prompts, a visual of what the app can produce, a sense of capability being installed. Don't just show a progress bar on a white screen.

The download should be resumable and tolerant of backgrounding. If the user leaves and returns, they should land back exactly where they left off.

---

### 2. The Prompt

Once the model is ready, the user arrives at the main screen. This is where they spend most of their time.

**The primary action is describing an image.** Voice is the natural default — image descriptions feel more like speech than typing. The design should make voice feel like the obvious first move, with text as a natural alternative.

The interface is conversational: the history of what the user has asked for, and what was generated, lives here. Think of it as a creative conversation with the app rather than a form to fill in.

**What this screen needs:**
- A clear, low-friction way to start a new prompt (voice or text)
- The conversation history — prompts and their resulting images
- Access to the current image in full detail

**What it should not have:**
- Sliders, settings, or parameters
- Model selection
- Anything that requires understanding how diffusion works

---

### 3. Generation

Image generation takes roughly 6–10 seconds on iPhone. This is long enough that silence or a bare spinner feels broken. The design needs to make waiting feel active, not stuck.

**The constraint:** don't show intermediate diffusion steps. They're visually noisy and confusing to anyone who doesn't understand the denoising process. The waiting state should feel intentional and calm.

Beyond that, the designer has latitude: motion, blur-to-sharp reveal, a subtle pulse, an animation that suggests something is being made. The tone should match the product — simple and considered, not playful or gamified.

---

### 4. The Result

The image appears. This is the payoff moment — it should feel like a reveal.

**Primary actions after generation:**
- **Save** — to the user's photo library
- **Share** — the native iOS share sheet (covers iMessage, AirDrop, social apps)
- **Try again** — same prompt, new generation
- **Refine** — edit the prompt and generate again

The image should be displayed at full prominence. Don't bury it in chrome.

---

## Image Format

All generated images are **768 × 768**. Square. This simplifies layout and is the right balance between quality and generation speed on iPhone.

---

## Content

LocalImage generates images on-device without Apple's content restrictions. Users can generate portraits and realistic images. The app has its own content filter that blocks explicit content, but is otherwise permissive.

This is a meaningful product differentiator and worth communicating clearly at first launch — "generates privately on your device" — without making it feel like the point of the app is to circumvent restrictions.

---

## Platform

iPhone is the primary target. iPad and Mac are in scope but secondary for this phase. Design for iPhone first; the layout should scale gracefully to larger screens.

---

## What This Brief Leaves Open

The following are intentional design decisions, not oversights:

- Visual language, color, and typography
- How the prompt input is styled and animated
- The specific treatment of the generation waiting state
- How images are displayed in the conversation history (grid, list, full-bleed scroll)
- The reveal transition when the generated image appears
- Iconography and naming throughout

---

## What to Hand Back

- Flow covering: first launch → download → first prompt → generation → result → save/share
- Key screen designs for each state
- The waiting/generation state treatment
- Notes on any journey decisions that need product input
