@AGENTS.md

<!-- Claude-specific notes below; all cross-tool content lives in AGENTS.md. -->

## Claude Code specifics

- **Draft-PR review loop** (AGENTS.md → Part 2 → "Draft-PR review loop"): the
  `/ship` skill automates the implement → draft-PR → review → gate → ready
  sequence. Its review step dispatches the `skeptical-reviewer` agent.
