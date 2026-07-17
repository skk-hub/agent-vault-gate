# agent-vault-gate

Mechanical trust for AI-written knowledge bases: a git commit gate and batch-review
workflow that let multiple AI agents write to one markdown vault **unattended**,
without a human reading every diff — extracted from a private personal knowledge
system where this has been running in production since mid-2026 (~230 documents,
several concurrent agent writers: Claude Code sessions, a headless auto-ingest
agent, and an always-on orchestrator).

The vault content stays private; this repo is the machinery, a synthetic sample
vault, and a test suite that proves each enforcement claim.

## The problem

If AI agents write to a knowledge base unattended, three things rot it:

1. **Silent destruction** — an agent "cleans up" or rewrites evidence it should have preserved.
2. **Copied-claim drift** — a fact duplicated onto a second page outlives the correction of the original. Every drift incident observed in production was this shape.
3. **Invisible change** — edits accumulate faster than any human reads diffs, so review silently stops happening.

## The invariant model

| Invariant | Enforcement |
|---|---|
| Evidence is append-only **by default** | `raw/` accepts new dated files only; edits/deletes blocked except via the explicit `[destructive]` path below |
| Deletions are loud | any deletion requires a `[destructive]` marker in the commit subject — those commits humans read line-by-line |
| Every claim page carries its contract | frontmatter must be complete: `title`, `type`, `area`, dates, `review_by` (staleness window), `sources` (citations into `raw/`), `status` |
| Pages can't lie about where they live | `area:` field must match the directory the page sits in |
| Every wiki change is announced | a change to a claim page without a `meta/changelog.md` entry is blocked — the changelog is the human review surface |
| Links don't rot | every `[[wikilink]]` in a staged file must resolve to an existing page (filename or title) |

The gate is **mechanical only** — 70 lines of PowerShell in a `commit-msg` hook
(`scripts/validate-vault.ps1`). Deliberately no LLM in the loop: a gate must be
deterministic, instant, and immune to persuasion.

## The review model

Machines gate every commit; humans review in **batches**. `scripts/review-digest.ps1`
shows everything since the last `reviewed` tag: the commit list, destructive commits
highlighted, the changelog delta (the actual review surface), and a diffstat.
`-Mark` moves the tag. This replaced per-commit human review, which stopped being
real the moment multiple agent sessions were committing concurrently — a review
step that can't keep up is a review step that isn't happening.

## Run the demo

```powershell
./test.ps1
```

Builds a throwaway git repo from `sample-vault/` and asserts the gate's verdict
for each violation class:

```
PASS  valid new page + changelog entry -> accepted
PASS  frontmatter missing review_by -> blocked
PASS  area field contradicts directory -> blocked
PASS  editing an evidence snapshot in raw/ -> blocked
PASS  same raw/ edit with [destructive] marker -> accepted (loud path)
PASS  deleting a page without [destructive] -> blocked
PASS  wiki edit without a changelog entry -> blocked
PASS  broken wikilink -> blocked
```

To use it on a real vault: copy `scripts/` in, and `hooks/commit-msg` to `.git/hooks/`.

## Threat model — what this does and does not stop

**Stops:** accidental destruction, structural rot (missing metadata, broken links),
silent unreviewed change, agents "fixing" evidence in place.

**Does not stop, by design:**

- **A false claim in valid clothing.** The gate checks shape, not truth. Truth is
  handled by separate processes in the production system: a contradiction log
  (conflicts get recorded, not silently resolved), `review_by` staleness windows,
  and a recurring reconcile pass that checks recorded infrastructure facts against
  the live machines — because *the vault is a claim; the machine is the truth.*
- **A hostile actor.** `git commit --no-verify` bypasses any hook. This is a
  guardrail against error and drift in cooperative-but-fallible agents, not a
  security boundary against an adversary. An adversarial writer needs server-side
  enforcement, which a personal vault doesn't warrant.
- **Prompt injection via ingested content.** Mitigated upstream in the ingest
  procedure (untrusted captures are quarantined as evidence, never executed as
  instructions), not by the gate.

## Field notes (why each rule exists)

Every rule was paid for by a real incident:

- **One home per claim / changelog-required:** a readiness score was copied onto a
  second page; the original was later corrected, the copy survived for weeks and
  kept being read. Corrections propagate only when there is nothing to propagate to.
- **Constraints, not lists:** a directory roster was copied into a config file that
  every session reads and none writes — a new directory appeared, and the stale
  list lied silently for six weeks. Rules are now stated as constraints checked
  against the filesystem, never as enumerations.
- **Verify against ground truth:** an agent once reported a task complete when it
  wasn't, and a green uptime monitor once hid a dead service (the port listened;
  the app was gone). Both taught the same lesson the gate encodes: a report is a
  claim, not a fact.

## Design decisions

- **Batch digest over per-commit review** — chosen when concurrent agent sessions
  made per-commit review fiction. The gate makes additive commits safe to land
  unreviewed; the `[destructive]` marker keeps the dangerous class loud.
- **Git as the audit log** — rejected a database/CRDT design: git already provides
  immutable history, authorship, and diffs; the vault is markdown so the audit
  layer costs nothing.
- **No LLM in the gate** — rejected an LLM-reviewer step at commit time:
  non-deterministic, slow, and an agent can talk another agent into things it
  cannot talk a regex into.

## Authorship

Built solo, pair-programming with Claude Code: the invariant model, the review
split, and the decisions above are mine; the implementation is AI-generated and
verified by behavior — the test suite in this repo is that discipline made concrete. The system exists precisely because AI output
can be confidently wrong — the production incident log above includes the AI
itself misreporting completion, which is what "gate everything mechanically"
is for.
