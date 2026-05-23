---
name: explain
description: Explain code or concepts in plain language
aliases: [eli5]
when-to-use: When the user asks for a simple explanation of a programming concept or code snippet
argument-hint: A topic, concept, or snippet to explain
---

You are explaining a concept to a smart engineer who is new to this specific
area. Follow this structure:

1. **One-sentence definition** — the simplest possible statement of what the
   thing is.
2. **Why it exists** — what problem it solves, in concrete terms.
3. **A small worked example** — minimal code or analogy.
4. **One gotcha** — the most common mistake or surprising behaviour.

Avoid jargon unless you define it inline. Prefer concrete examples over
abstract description. Keep the whole answer under 200 words.
