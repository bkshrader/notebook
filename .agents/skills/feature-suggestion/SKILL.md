---
name: feature-suggestion
description: Turn a rough feature idea into prior-art research, a lightweight PRD, and a draft GitHub PR for later roadmap discussion — without implementing anything. Use this whenever the user wants to propose, scope, or float a new feature for this project, wants to research existing tools/formats/standards as prior art for an idea, or says things like "add this to the roadmap," "let's write up a feature suggestion," "research prior art for X," or "turn this into a PRD/draft PR." Runs as a sequence of phases (research, draft, lock copy, branch/PR) and pauses for the user's explicit go-ahead before moving from one phase to the next — never skip a gate or combine phases even if the user's answers seem to imply the next step.
---

# Feature Suggestion Workflow

This skill turns "I'm thinking about feature X" into a draft PR containing a PRD,
so the idea is captured and shareable without committing to any implementation or
design work. It is intentionally slow and gated — the point is deliberate pacing
across four phases, each of which ends with an explicit stop for the user's
go-ahead. Do not batch phases together even if you think you know what the user
will say next; the pauses are the feature, not overhead to optimize away.

## Before starting

Confirm you understand the feature idea at a one-or-two-sentence level (the
problem it addresses, and any tool/format/prior art the user already has in
mind). If the idea is too vague to research meaningfully, ask a clarifying
question before Phase 1.

## Phase 1: Research prior art

Research existing software, tools, standards, or formats that are prior art for
this idea, including the project codebase where appropriate. Don't limit the
search to the user's own framing — actively suggest adjacent tools, libraries,
or specs they might not know about. This is a normal back-and-forth conversation,
not a one-shot dump: let findings surface, ask follow-up questions, and let the
user redirect if a line of research isn't useful.

As part of this phase, flag any architecture / separation-of-concerns
considerations for how the idea would fit into this codebase — for example,
whether it should be a bespoke internal format/feature or whether it should
adopt or adapt an existing open spec (the way Jupyter notebooks are `.ipynb`,
a documented external format, rather than being owned by any one frontend).

**Gate:** Do not move to Phase 2 until the user says they're ready to draft —
something like "let's write it up" or "draft the PRD now." If they're still
exploring, keep researching.

## Phase 2: Draft the PRD

Write a PRD to a scratchpad file, *not* the project directory. Use these
sections, adapting/omitting a section only when it's genuinely not applicable
(state that explicitly rather than dropping it silently):

- **Problem** — what's hard today and why
- **Inspiration** — the prior art/tools that motivate this, and which specific
  ideas from them are worth adapting
- **Proposed Feature (high level)** — what the feature would do, kept at a
  conceptual level
- **Architectural Concern(s)** — separation-of-concerns risks and the
  recommended approach (e.g., adopt an existing format/spec vs. bespoke)
- **Other Directly Relevant Information** — a fuller list of the
  standards/tools surfaced in Phase 1, even ones not chosen, so the reasoning
  is preserved
- **Open Questions (deferred)** — concrete design questions intentionally left
  unresolved
- **Status** — state plainly that this is unscheduled / a roadmap candidate
  with no implementation work started

Keep implementation detail out of it — this is a roadmap candidate, not a spec.

**Gate:** Do not move to Phase 3 until the user says the copy is locked.
Expect and apply copy edits directly without re-litigating them — the user is
refining wording, not asking you to reopen the discussion.

## Phase 3: Confirm the branch name

Propose a short, kebab-case branch name under one of these prefixes: `feature/`,
`refactor/`, `bugfix/`, `docs/`, `chore/` (e.g., `feature/evidence-map`,
`refactor/jami-collab`) — no ticket numbers or dates. Pick the prefix that
best matches what the suggestion actually is (e.g. `refactor/` for replacing
the mechanism behind an existing feature rather than adding a new one,
`chore/` for tooling/maintenance-shaped suggestions), and ask the user to
confirm or correct both the prefix and the name.

**Gate:** Do not create the branch until the user confirms the name.

## Phase 4: Branch + draft PR

Once the name is confirmed:

1. Check `git status` — if the working tree isn't clean, stop and ask how to
   proceed rather than switching branches over uncommitted work.
2. Create the branch off `main`: `git checkout -b <prefix>/<name>`
3. Push it. GitHub requires at least one commit of difference to open a PR —
   if the branch has no changes yet, add an empty commit first:
   ```
   git commit --allow-empty -m "Start <prefix>/<name> branch

   No code changes yet — branch opened to host the feature suggestion PRD as a draft PR for discussion.

   Co-Authored-By: Claude <noreply@anthropic.com>"
   ```
4. Open a **draft** PR against `main` using `gh pr create --draft --body-file
   <path>`, pointing at that file rather than passing the body inline — this
   avoids shell-escaping issues with quotes/apostrophes in the PRD text.
   Title it by taking the PRD's title and replacing the word "PRD" with
   "Feature Suggestion" (if the title didn't contain "PRD," just use it as-is
   with a "Feature Suggestion:" prefix).
5. Report back just the PR URL — no further narration needed.

Do not implement any part of the feature itself at any point in this process.
The deliverable is the draft PR, not code.
