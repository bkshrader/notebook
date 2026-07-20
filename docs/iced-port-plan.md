# GPUI → iced Porting Plan

Status: analysis / planning only. No code changes yet.
Date: 2026-07-20. Based on codebase analysis at commit `b623c2a933` plus external
research on iced 0.14.0 (released 2025-12-07).

---

## 1. Executive summary

**GPUI is not this app's renderer — it is its application runtime.** 176 of 237
workspace crates depend on gpui. Core domain types (`Buffer`, `Worktree`,
`MultiBuffer`, `Project`, `Client`) *are* `gpui::Entity`s; ~95% of `Editor`'s
methods thread a gpui context; the `Item`/`Panel` traits that define the
workspace require `Render + Focusable + EventEmitter`; and ~4,275 tests run on
gpui's deterministic test harness.

**Consequence:** "porting to iced" decomposes into two very different projects:

1. **Untangling the runtime** (entity model, executor, events) from the
   framework — hard but mechanical, framework-neutral, and valuable no matter
   what UI library ends up on top.
2. **Rewriting the UI layer** (~editor element, workspace shell, ~50-component
   `ui` library, keymap dispatch, focus) against iced — a rewrite, not a port,
   because iced's Elm architecture and widget model share nothing with gpui's.

**Honest feasibility assessment:** iced is a risky target for this app
specifically. Its `text_editor` widget is unsuitable for a code/notes editor
(no rope, no virtualization, known CPU issues on large documents — System76's
own cosmic-edit bypassed it and wrote a custom widget over cosmic-text). iced
has no keymap/action system, no list virtualization, no upstream
accessibility, an explicitly-unstable API, and ~7–15 month release gaps. No
Zed-class editor exists on iced. A port means rebuilding the editor element,
virtualized lists, keymap dispatch, and focus management from scratch as
custom iced widgets.

The plan below is therefore gated: **Phases 0–2 are no-regret work** that
improves the codebase regardless of framework choice (and directly serves the
open keep-vendored / fork-and-own / migrate / defer decision). **Phase 3 is a
timeboxed iced prototype with explicit go/no-go criteria** before any
large-scale UI rewrite begins in Phase 4.

---

## 2. Coupling analysis findings

### 2.1 The four coupling layers

**Layer A — Entity/Context ownership + reactivity model (deepest).**
`App`, `Entity<T>`, `Context<T>`, `cx.subscribe`/`cx.observe`,
`EventEmitter`, `Global`. Usage: `cx.new(` ×2,506 across 424 files;
`cx.subscribe` ×486; `cx.observe` ×400; `Global` impls ×171. Woven through
the public APIs of `project` (Entity refs ×1,074), `multi_buffer`,
`worktree`, `language` (`Buffer` is an Entity), `buffer_diff`, `client`.
This is the app's object-ownership and observer system, independent of
rendering but defined inside gpui.

**Layer B — Async runtime.** `Task`, `cx.spawn` (×1,467 / 382 files),
`BackgroundExecutor`/`ForegroundExecutor` (×689 / 141 files). Good news:
this fork's gpui **already delegates entirely to the standalone
`crates/scheduler` crate** (gpui-free, miri-tested in CI). gpui's
`executor.rs` is a thin re-export/wrapper. Even shallow crates (`fs`, `lsp`,
`git`, `db`, `prettier`, `task`) touch gpui only for this + `SharedString` +
`Global`.

**Layer C — Element/render layer.** `impl Render` ×497 / 346 files;
`IntoElement` ×1,243 / 419 files. Concentrations:

- `crates/editor`: `element.rs` + `element/` ≈ 14.6k lines (68
  paint/layout/prepaint methods) — but `editor.rs` itself (12.5k lines) is
  `Render + Focusable` with ~95% of its 476 methods taking gpui contexts.
- `crates/workspace` (~49k lines): owns real OS-window concepts
  (`WindowHandle` ×22, `WindowBounds`, focus routing); `Item` and `Panel`
  traits require `Focusable + EventEmitter + Render`, so every tab and dock
  panel is a gpui view by construction.
- `crates/ui` (~28k lines): ~50 components, all
  `#[derive(IntoElement)] + impl RenderOnce` (×70).
- Text pipeline junction: tree-sitter chunks → `syntax_highlight_id` → theme
  `HighlightStyle` (gpui type, in `display_map.rs`) → `TextRun` →
  `window.text_system().shape_line()` → `ShapedLine` (in `element.rs`).
  gpui text types (`Font`, `LineLayout`, `HighlightStyle`, `Hsla`) leak into
  otherwise-pure logic (`display_map`, `movement`, `theme`).

**Layer D — Cross-cutting services.** Actions/keymap (`actions!` ×441 /
143 files, `KeyBinding` ×655 — concentrated in `zed_actions`,
`editor/actions.rs`, `vim`, `settings/keymap_file.rs`); `SharedString`
(already its own crate, `gpui_shared_string`); value types
(`Pixels`, `Rgba`, `FontWeight`) leaking into `settings`; the
`#[gpui::test]` harness (~4,275 attributes / 316 files).

### 2.2 Already-clean assets (keep as-is under any framework)

- **Framework-free crates:** `text`, `rope`, `clock`, `util`,
  `node_runtime`, `scheduler`, `collections`, `fuzzy`, `sum_tree` — plus the
  many parser/provider leaf crates (~3,300 plain `#[test]`s live here).
- **Pre-existing seams (this fork's gpui is already decomposed):**
  `gpui_platform` (backend selection), per-OS backends
  (`gpui_windows`/`gpui_macos`/`gpui_linux`/`gpui_web`), `gpui_wgpu`
  (portable renderer **with a cosmic-text text system already** —
  `gpui_wgpu/cosmic_text_system.rs`), `scheduler`, `gpui_shared_string`,
  `gpui_util`, `gpui_tokio`. App code almost never names renderer symbols
  directly — rendering is fully encapsulated behind the element/window API.
- **Framework-independent test utilities:** `util::test`
  (`marked_text_ranges`, `TempTree`, `sample_text`), `util::RandomCharIter`,
  the `scheduler` test scheduler (deterministic, seeded, miri-tested).

### 2.3 Oddballs

- `terminal` is the only logic crate with genuine render-type coupling
  (fonts, pixels, ~67 render refs).
- `FakeFs` needs a `BackgroundExecutor` (→ `scheduler`), not a full App.
- Visual/screenshot testing exists (`crates/zed/src/zed/visual_tests.rs`)
  but is macOS-only, opt-in, and not run in CI. Deterministic tests verify
  layout via logical assertions (`VisualTestContext::draw`), not pixels.

---

## 3. iced fit assessment (0.14.0, Dec 2025)

| Need | iced status | Gap severity |
|---|---|---|
| License | MIT — GPLv3-compatible | none |
| Multi-window | First-class (`Daemon` API) | none |
| Async | `Task`/`Subscription`; tokio or smol executors | low — must funnel through message loop |
| Custom widgets | Full `Widget` trait; `shader` widget = raw wgpu pipeline; canvas | low-moderate |
| Split panes | Built-in `pane_grid` widget | low |
| IME | Landed in 0.14 | low (new, unproven) |
| Text editing | `text_editor` = plain-text box; no rope, no virtualization, CPU issues (#2477); cosmic-edit bypassed it | **critical — must build custom editor widget** |
| Large lists/trees | No virtualization; layout is O(n); 0.14 only culls drawing | **high — hand-roll** |
| Keymap/actions | None; `keyboard::on_key_press` only | **high — port gpui keymap crate** |
| Focus | Id-based, weak; long-open issues (#2030) | high |
| Accessibility | Absent upstream (#552 open since 2020); AccessKit "planned" | high (gpui here has AccessKit integration) |
| Elm MVU vs entity graph | Opposed architectures; no sanctioned component encapsulation | **high — architectural bridge needed** |
| API stability | Explicitly none; 7–15 mo release gaps; COSMIC soft-forked (libcosmic) | high (mitigation: vendor/pin, same as today) |
| Animation, theming, styling | Adequate (0.14 Animation API, closure styling, Oklch palettes) | low |

**What carries over from this fork regardless:** cosmic-text experience
(`gpui_wgpu` already ships a cosmic-text text system — iced's text stack is
also cosmic-text), the `scheduler` crate, all Layer-A-extracted model code,
and the keymap *matching logic* (parsing/matching is mostly pure and can be
re-hosted on iced events).

---

## 4. The plan

### Phase 0 — Shrink the surface before touching anything

Every crate deleted is a crate never ported. Per the project vision
(academic note-taking app; debugger and remote-dev already slated for
removal; no extensions), candidates to delete outright:

Decided (2026-07-20):

- **Delete (planned already):** `dap`, `dap_adapters`, `debugger_ui`,
  `debugger_tools`, `debug_adapter_extension`; remote-dev (`remote`,
  `remote_server`, ...); extension system (`extension`, `extension_host`,
  `extension_cli`, ...).
- **Keep:** the AI/agent stack (`agent`, `agent_ui`, ...), `vim`,
  `terminal`. These stay in the port scope, including their large test and
  `cx.new` populations.
- **Collab: keep the feature, replace the implementation.** The plan is a
  from-scratch **p2p** collaboration layer instead of Zed's server
  infrastructure. Implication: Zed's server-tied backend (`collab` server
  crate, cloud/RPC plumbing) is deletable, but the *feature surface*
  (`collab_ui`, `call`, `channel`, followers, `FollowableItem`/leader-state
  in `workspace`) remains in the UI-port scope and will be re-pointed at the
  new p2p backend. Sequencing the p2p rewrite vs. the UI port is an open
  decision (doing both simultaneously to the same code is the riskiest
  ordering).
- **Still undecided:** telemetry, `auto_update`, misc candidates.

Deliverable: an explicit keep/delete/defer list; then do the deletions.
(Deletion is also the cheapest way to make every later phase's grep counts,
builds, and test runs faster.)

### Phase 1 — Extract the runtime from the framework (no-regret)

Goal: **core logic crates compile with zero dependency on `gpui` proper** —
only on small framework-neutral crates. This is the keystone of the whole
effort and is exactly the direction the existing gpui decomposition
(`scheduler`, `gpui_shared_string`, `gpui_util`) already points.

1. **`SharedString`** — depend on `gpui_shared_string` directly in `git`,
   `task`, `lsp`, `fs`, `settings` (drop the `gpui::` re-export path).
2. **Executor** — depend on `scheduler` directly for `Task`,
   `BackgroundExecutor` in the shallow crates (`fs`, `lsp`, `git`, `db`,
   `prettier`, `task`). gpui already just re-exports these types, so this is
   mostly import rewriting. Handle `AsyncApp`-taking APIs by narrowing them
   to executor params.
3. **Value types** — new tiny crate (e.g. `geometry`/`ui_types`) for
   `Pixels`, `Point`, `Size`, `Rgba`/`Hsla`, `FontWeight`, `FontFeatures`,
   `Modifiers`, `HighlightStyle` — or move them out of gpui core into an
   existing seam crate. Unblocks `settings`, `theme`, `display_map`,
   `terminal` without behavior change.
4. **The entity model (the big one)** — lift `App`/`Entity<T>`/`Context<T>`/
   `entity_map`/`subscription`/`EventEmitter`/`Global` out of gpui into a
   standalone `entity` crate with **no render, window, element, or platform
   dependencies** (keep `gpui` re-exporting it so UI code is untouched).
   Then repoint `project`, `language`, `worktree`, `multi_buffer`,
   `buffer_diff`, `client`, `settings`, `db` at `entity` + `scheduler`.
   This preserves every API and behavior — no rewrite of Buffer/Project —
   while making the model layer UI-framework-free. It also becomes the
   state layer *under* iced later (see Phase 4 architecture).
5. **Actions out of logic crates** — move the stray `actions!` blocks in
   `git`, `client`, `terminal`, `settings` up into UI crates.
6. **`terminal`** — split render types (fonts/pixels) from the alacritty
   logic, or accept it as UI-layer.

Exit criterion (mechanically verifiable):
`cargo tree -p project -p language -p worktree -p multi_buffer -p fs -p lsp
-p git -p settings -i gpui` shows no `gpui` (only `entity`, `scheduler`,
`gpui_shared_string`, value-types crate).

### Phase 2 — Verification harness (before any UI swap)

The port's safety net. Three tiers, matching the three coupling depths found
in the test census:

1. **Harness-only tests** (seeded `StdRng`, no App): `text`/`rope`/`patch`
   randomized suites. Re-host the `#[gpui::test]` seeding/ITERATIONS/SEED
   machinery on `scheduler` (where the `TestScheduler` already lives) so
   these run without gpui. Cheap; do during Phase 1.
2. **Executor-level tests** (TestAppContext scheduler, no windows):
   `project`, `fs`, async-logic tests, `FakeFs`. After the entity-model
   extraction, port `TestAppContext` minus its window/input half into the
   `entity` crate's test support. Target: the ~128 project integration
   tests and language/buffer tests run green with no gpui.
3. **Behavioral characterization suite** (the cross-framework contract):
   Write/curate a headless suite that pins down *editor behavior* in
   framework-neutral terms — marked-text in → operations → marked-text out
   (`util::test::marked_text_ranges` already gives the vocabulary). Editing,
   movement, selection, folding, undo, multi-cursor, search. Today these
   live inside `editor_tests.rs` (473 tests) behind `EditorTestContext`
   (fully window-bound); the subset expressible as
   buffer/display-map-level assertions becomes the suite both UIs must pass.
   This is the primary "did the port preserve behavior?" instrument.
4. **Visual baselines**: extend the existing screenshot system
   (`zed/src/zed/visual_tests.rs`) to Windows (offscreen via `gpui_wgpu` or
   the DirectX path) and capture golden images of key screens *before* the
   port. Post-port, re-capture on iced and diff — expect intentional
   differences, so use it as a human review aid, not a hard gate.
5. **Performance baselines**: scripted benchmarks now, re-run post-port —
   keystroke-to-frame latency, open/scroll a 10k-line file + a large
   markdown/LaTeX doc, file-tree with thousands of entries, startup time.
   iced's known weak spots (text perf, no virtualization) make this the
   most likely failure axis; numeric baselines make "is it acceptable?"
   answerable.

### Phase 3 — iced spike (timeboxed, go/no-go gate)

Build a throwaway prototype **against the real extracted model crates**
(Phase 1 output), not toy data:

- Custom iced `Widget` rendering a real `MultiBuffer` through the display-map
  stack: virtualized lines, cosmic-text shaping, syntax highlighting from
  tree-sitter chunks, cursor/selection painting, mouse hit-testing.
- Keymap dispatch prototype: gpui `keymap` matching logic re-hosted on iced
  keyboard events, with key-context resolution (editor vs panel focus).
- Workspace skeleton: `pane_grid` with two editors + a file tree
  (hand-virtualized list), focus moving between them.
- IME check (relevant for LaTeX/international input) and Windows-first
  validation (primary dev platform).

Go/no-go criteria (write numbers down before starting): typing latency and
scroll perf within budget vs Phase 2 baselines on the 10k-line file; keymap +
focus model workable; no blocker in multi-pane/multi-window; subjective
assessment of Elm-architecture friction against the entity model. **If
no-go:** Phases 0–2 are still fully banked; fall back to the standing
options (fork-and-own gpui / defer / evaluate Floem–Xilem–Slint with the
same spike template).

### Phase 4 — UI rewrite on iced (only if Phase 3 passes)

Architecture: **entities below, Elm above.** The extracted `entity` crate
remains the state layer (Buffer/Project/Worktree unchanged). iced owns the
view: a coarse per-screen `Message` enum whose update handlers call entity
methods; entity events bridge into the message loop via a `Subscription`
backed by a channel. This avoids both a full Elm-ification of 250k+ lines of
model code and Message-enum explosion.

Mapping table:

| gpui concept | iced replacement |
|---|---|
| `Entity<T>` / `Context<T>` model | kept — extracted `entity` crate as state layer |
| `cx.spawn` / `Task` | kept (`scheduler`) in model; `Task::perform`/`Subscription` at the UI boundary |
| `EventEmitter` + `cx.subscribe` | kept in model; bridged to `Message` via channel `Subscription` |
| `impl Render` views | per-screen `view()` fns + `Element::map` composition |
| `ui` crate (`RenderOnce` components) | rewrite as iced widget helper fns / custom widgets (~50 components; many become trivial styled built-ins) |
| `EditorElement` | fully custom `Widget` (Phase 3 prototype hardened): own layout, cosmic-text, virtualization, optional `shader` pipeline |
| `workspace` panes/docks | `pane_grid` + custom dock containers |
| `Item`/`Panel` traits | new traits returning `Element<Message>`, without `Render`/`Focusable` supertraits |
| actions + keymap | ported `keymap` matcher over iced keyboard events; actions become messages |
| `FocusHandle`/key contexts | hand-rolled focus registry (iced's weakest area) |
| `theme` (`Hsla`, `HighlightStyle`) | kept via value-types crate; adapt to iced styling closures |
| multi-window | `Daemon` API |
| `#[gpui::test]` UI tests | iced 0.14 headless/e2e testing + Phase 2 characterization suite |

Order of attack (each step ships a runnable app):
1. Shell: window + `pane_grid` + theme + keymap dispatch + file tree.
2. Editor widget for read-only viewing; then editing; then multi-cursor etc.,
   driven by the characterization suite.
3. Panels/pickers/modals (project panel, outline, command palette via
   ported `fuzzy`).
4. Feature panels (markdown preview, terminal, git, search).
5. Delete gpui render/platform crates; keep `scheduler`, `entity`,
   `gpui_shared_string`, value types.

### Phase 5 — Verification of the port

- Characterization suite (Phase 2.3) green on iced.
- Model-layer test tiers (Phase 2.1/2.2) green — these never stopped running.
- Perf benchmarks vs Phase 2.5 baselines within agreed budgets.
- Visual review against Phase 2.4 golden images.
- Manual test script per feature area (input methods, drag-drop, clipboard,
  multi-window, HiDPI, Windows/macOS/Linux).
- CI: keep nextest matrix; replace `#[gpui::test]` runner with the
  re-hosted scheduler harness + iced headless tests.

---

## 5. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Editor perf on iced below par (text shaping, no virtualization) | High | Fatal to port | Phase 3 gate with numeric budgets; custom widget owns its layout/draw |
| Elm/entity impedance mismatch produces unmaintainable bridge code | Medium | High | Phase 4 architecture keeps entities as state layer; spike evaluates friction early |
| iced API churn breaks the port mid-flight (0.13→0.14 was 15 months + breaking) | High | Medium | Vendor/pin iced exactly as gpui is vendored today; budget for one upgrade cycle |
| Effort exceeds solo capacity (UI layer ≈ 100k+ lines to rewrite even post-deletion) | High | High | Phase 0 deletions first; phases individually valuable; explicit bail-out points |
| Accessibility regression (gpui has AccessKit; iced upstream doesn't) | Certain (today) | Medium | Track iced AccessKit work; note libcosmic/plushie-iced carry patches |
| Test suite becomes the bottleneck (4,275 gpui tests) | Medium | Medium | Phase 0 deletes big test populations; Phase 2 re-hosts tiers 1–2 early; window-bound UI tests are rewritten only where characterization can't cover |
| Entity-model extraction harder than expected (hidden render deps in `App`) | Medium | High | It's the first major task — fails fast; gpui's existing sub-crate split suggests feasibility |

---

## 6. Open decisions

Resolved 2026-07-20:

1. **Phase 0 scope** — decided; see Phase 0. Agent/vim/terminal stay; collab
   feature stays with a planned p2p backend rewrite.
2. **Framework decision timing** — moved ahead of everything else: a
   multi-candidate spike (standalone stress prototypes + maturity
   comparison, not dependent on Phase 1) runs first, and the framework is
   settled before Phases 0–2 begin. Candidates: all viable Rust GUI
   frameworks judged on maturity (relative to the Rust GUI ecosystem),
   stability, performance, active maintenance, and cross-platform support.

All resolved (2026-07-20):

3. **Framework: stay on vendored GPUI (fork-and-own).** See §7. Upstream
   updates via selective cherry-pick of `crates/gpui*`/`crates/scheduler`
   commits; keep own gpui patches minimal (documented patch queue or shims
   in app crates) to keep that channel cheap.
4. **Phases 0–2 still happen**, as follow-up work in separate PRs (not in
   PR #14). Rationale: deletions shrink build/test times; runtime extraction
   reduces surface exposed to upstream drift and keeps the Floem escape
   hatch cheap.
5. **P2p collab rewrite: deferred until core notebook features ship.**
6. **Visual/perf baselines: deferred**, revisit later.
7. **Telemetry / auto_update: handled in other PRs.**

---

## 7. Framework decision — spike results (2026-07-20)

Five hands-on stress prototypes (identical spec: 10k-line document, per-token
coloring, virtualized scrolling, basic editing, instrumented stress pass with
real measured frame times, on Windows 10) plus a full-field maturity survey.

### Spike scoreboard

| Framework (version) | Fitness | Measured performance | Killer findings |
|---|---|---|---|
| **Floem 0.2.0** | **8/10** | 60fps GPU both phases; **7.9–9.2ms/frame avg on pure-CPU renderer**, two panes | Built-in `text_editor` (rope, gutter, selection, wrapping, IME preedit, replaceable keymap) usable outside Lapce; whole spike ~400 lines. Costs: crates.io stale since Nov 2024 (git-pin), thin docs, silent-failure footguns (0x0 layout, timer starvation), small team |
| **egui 0.35.0** | 6/10 | Custom widget: ~1.8ms CPU scrolling 2 panes, vsync-locked; stock `TextEdit`: **21–34ms CPU per keystroke — collapses** | Must hand-build editor widget + keymap + focus + IME (IME pipeline is `TextEdit`-internal, backend-fragile); no styling system; API churn each minor |
| **Masonry 0.4 + Parley 0.6** | 6/10 today | vsync-locked; **1.2–1.6ms paint CPU re-shaping ~40 lines/frame with zero caching** | Parley per-token styling, caret geometry, hit-testing excellent; AccessKit first-class (only spiked framework). Alpha churn; masonry pins parley 0.6 while parley is at 0.11; docs = examples dir. Durable assets are Parley/Vello/AccessKit; Masonry itself is a thin replaceable shell |
| **iced 0.14.0** | 5/10 | vsync-locked 18ms, p95 +0.3ms, two panes via canvas | `text_editor` dead end; no text-measurement API in canvas; no focus for custom widgets; **no IME at all for custom widgets in stable API**; no keymap system |
| **Slint 1.17.1** | 3.5/10 | **Cannot hold 60Hz**: 20.5ms avg dual-pane, 10–14ms render CPU | No rich text (element-per-token workaround), no canvas/imperative paint path, no text-metrics API, no IME composition for custom widgets, `ListView` needs uniform row heights (hostile to variable-height notebook cells). Fine for chrome, disqualified for the buffer view |

### Survey ranking (maturity/maintenance axis)

1. **Vendored GPUI (fork-and-own)** — Zed paused community-facing GPUI work
   (Feb 2026) and crates.io is dead at 0.2.2, but for a never-merge-upstream
   vendored fork this changes almost nothing: Zed keeps developing GPUI
   intensely for exactly this workload. gpui-ce (community fork) exists but
   is thin.
2. **Floem** — only framework with real shipped-editor prior art (Lapce),
   but organizationally weakest of the serious options: stale publishes,
   low bus factor, commercial focus elsewhere; external 2025 testing
   reported Windows IME activation and screen-reader failures (the spike
   confirmed IME *plumbing* exists but did not exercise real CJK input —
   unresolved discrepancy, must be tested by hand before any Floem bet).
3. **Slint** — best-run project (company-backed, stable API, GPLv3 option),
   but the spike disqualified it for the editor surface.
4. **iced** — COSMIC proves the stack; accessibility absent; ~1 release/yr.
5. **Xilem/Masonry** — not adoptable today; best trajectory
   (Parley/Vello/AccessKit are healthy and independently consumable).
   egui: disqualified for large text by both maintainer guidance and
   measurement.

### Consolidated assessment

Every alternative shares one shape: **the editor core is a from-scratch
rebuild** (rope→display-map→virtualized shaped text, selection, IME, keymap,
focus), on top of the UI-layer rewrite the port already required. The spikes
show raw performance is achievable on several stacks — the differentiator is
how much editor infrastructure the framework contributes. Only Floem
contributes any (Lapce's), and adopting it swaps Zed's editor stack for a
smaller one maintained by a smaller team with a worse Windows story.

Recommendation: **stay on vendored GPUI (fork-and-own)** — the Feb 2026
upstream-community pause does not materially harm a vendored never-merge
fork, and no challenger offers a net reduction in total work or risk.
**Fallback if GPUI ever becomes untenable: Floem** (after hands-on Windows
IME verification), with **Parley/Vello/AccessKit** as the long-horizon
2027+ watch list. Phases 0–2 of this plan (scope deletion, runtime
extraction, verification harness) remain worth executing under fork-and-own
— they reduce gpui surface area and keep the escape hatch real.

Spike code: session scratchpad `spike-{iced,floem,slint,egui,masonry}/`
(temp location — copy out to keep).
