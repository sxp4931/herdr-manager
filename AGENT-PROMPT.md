# Agent prompt — plan "Herdr Manager"

Paste everything below the line into the agent. It is written for an agent with
shell access on the same Mac where herdr is installed and running.

---

## Role

You are a systems architect. Produce a **design and build plan** for a small
personal tool. **Do not write implementation code.** Interface signatures,
schemas, and pseudocode are in scope; working modules are not.

## Context

I run a lot of AI coding agents at once through **herdr**
(<https://github.com/ogulcancelik/herdr>, <https://herdr.dev>) — an open-source
Rust terminal multiplexer built specifically for AI coding agents. What I know
about it, all of which you must **verify against the actual binary and source on
this machine** before relying on any of it:

- Single ~10 MB Rust binary, AGPL-3.0, runs on macOS. Organises work into
  **workspaces (spaces) → tabs → panes**, each pane typically running one agent
  (Claude Code, Codex, Gemini CLI, and others).
- Runs a **background server**, so sessions survive detach/reattach, including
  over SSH.
- Tracks **semantic agent state** — `blocked`, `working`, `done`, `idle` — and
  surfaces it in a sidebar.
- Exposes a **CLI and a local JSON socket API**. Agents can reportedly create
  workspaces, split panes, spawn helpers, and subscribe to state changes.

The problem: herdr shows me state, but I still have to go hunting pane by pane.
I want one place — and one *agent* — that knows the whole herd.

## What I want built (this is the thing you are planning)

**Herdr Manager**: a lightweight **native macOS app** plus an **MCP server**,
both driving the same core, so that:

- **I** get a single UI showing every space, session, and agent with live status,
  and can act on any of them in one or two clicks.
- **An orchestrating agent of my choice** gets MCP tools over the same
  capabilities, so I can say things like:
  - "What's the status across everything right now?"
  - "Session X looks stuck — what's blocking it?"
  - "Unblock it / answer that prompt / tell it to continue."
  - "Spin up a new session in repo Y running Claude Code with this brief."
  - "Kill the three idle ones."

Both paths must operate on the same live state — the UI is not a separate
reimplementation.

### Constraints

- Personal tool, one user, one Mac. **No auth, no multi-tenancy, no cloud, no
  distribution, no code signing.** Optimise for my daily use, nothing else.
- **Lightweight.** Every dependency and every background process must earn its
  place. Flag anything heavy explicitly.
- **The UI has to be genuinely good** — fast, legible at a glance, obvious. This
  is a tool I'll stare at all day. Treat UI quality as a functional requirement,
  not polish.
- herdr is young software. Assume its API will change; isolate it.

## Non-negotiable working method

1. **Verify before you assert.** Read herdr's actual source, run `herdr --help`
   and every relevant subcommand, inspect the socket API by connecting to it, and
   look at whatever state files or config it keeps on disk. Quote real output.
2. **Label every claim** as `[verified]` (you ran it or read the source) or
   `[assumed]` (you inferred it). A plan built on unlabelled guesses is worthless
   to me.
3. Where a capability I asked for **is not exposed**, say so plainly and cost out
   the fallbacks (shelling the CLI, reading state files, PTY scraping, patching
   herdr) rather than quietly designing around a feature that doesn't exist.
4. **Ask me** about decisions that are genuinely mine — product behaviour, risk
   tolerance, how much autonomy the agent gets. Don't ask me about things you can
   determine by reading the source.

## The hard part, which most of the plan should be about

"**What's stopping this session, and how do I get it moving?**" is the actual
product. Everything else is plumbing. Address specifically:

- Can the socket API or CLI expose **pane output / scrollback**? Reading the last
  N lines is almost certainly required to answer "what's it waiting on." If it
  can't, that's the single biggest design constraint — find out first.
- What does **stuck** actually mean operationally? `blocked` state? `working`
  with no output for N minutes? Sitting on a permission prompt? Crashed process
  with a live pane? Define detectable signatures for each and how they're
  distinguished.
- Can input be **sent into a pane** programmatically, and how is that made safe?
- **Subscribe vs poll** for state changes: what does herdr support, what's the
  latency and cost of each.

## Safety

An LLM will be able to type into live coding-agent sessions and kill processes.
Design for that: which operations are freely agent-invokable vs. require my
confirmation, why there is no free-form shell passthrough in the MCP surface,
what's rate-limited, what's logged, and what an agent misfiring can and cannot
destroy.

## Deliverable

A single markdown document saved to
`/Users/admin/Documents/Herdr Manager/PLAN.md`, containing:

1. **Findings** — what herdr actually exposes, with evidence (command output,
   source references, socket transcripts).
2. **Capability matrix** — desired capability → available mechanism → confidence
   → fallback if unavailable.
3. **Architecture** — components, process model, data flow, and where the herdr
   adapter boundary sits. Include a diagram.
4. **State model** — the entities (space, session, agent, pane, status), how they
   map to herdr's own concepts, and how sync is maintained.
5. **MCP tool surface** — exact tool names, parameters, return shapes, and two or
   three worked example transcripts of me talking to the orchestrating agent.
   Small, sharply-named, bounded tools; no god-tool.
6. **UI design** — screens, layout, the at-a-glance status view, what's reachable
   in one click, keyboard behaviour, and how notifications work.
7. **Stuck-session diagnosis** — the detection heuristics and the remediation
   flow, per the section above.
8. **Safety and failure modes** — including what happens when herdr's server is
   down, restarts, or changes its API shape.
9. **Phased build plan** — thinnest possible end-to-end vertical slice first
   (something real working on day one), each later phase independently useful.
   Per phase: scope, acceptance evidence, and rough effort.
10. **Open questions for me** — the decisions you need from me, each stated as a
    concrete choice with your recommendation.
11. **Risks** — ranked, with the mitigation or the reason it's accepted.

Keep it dense. I'd rather read four tight pages than twenty padded ones. Where
you'd otherwise write a paragraph of hedging, write the recommendation and one
line of reasoning.
