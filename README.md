# agent-vault-gate

Pre-commit checks for a few conventions in a markdown vault, plus a digest for reviewing commits
in batches. Extracted from a private personal knowledge base that several AI agents write to
(Claude Code sessions, a headless ingest job, an always-on orchestrator). The vault itself stays
private; this repo holds the hook, the digest script, a synthetic sample vault and a test script.

## What the hook checks

`hooks/commit-msg` runs `scripts/validate-vault.ps1` (85 lines of PowerShell) against the staged
files of the commit:

- A file under `raw/` can be added. Editing or deleting one is blocked unless the commit subject
  starts with `[destructive]`.
- Deleting any file is blocked without that same subject prefix.
- An added or changed markdown file under `areas/` (four housekeeping filenames excepted) has to
  open with frontmatter carrying eight nonempty fields: `title`, `type`, `area`, `created`,
  `updated`, `review_by`, `sources`, `status`. Its `area` value has to match the directory it sits
  in.
- If any such page changed, `meta/changelog.md` has to be staged in the same commit. The hook checks
  that the file is staged; it does not read the entry.
- Every `[[wikilink]]` in a staged markdown file under `areas/`, `wiki/` or `meta/` has to resolve to
  a page in the index, by filename or by frontmatter title. Links in files that were not staged are
  not checked, so a `[destructive]` deletion can leave links elsewhere broken.

Staged paths are read with `git diff --cached -z` and `core.quotepath=false`, so a filename with a
non-ASCII character, a quote or a newline goes through the same checks. An earlier version missed
those, and the fix is in the history with a test for each case.

## What it does not do

- It checks shape, and only shape. A wrong claim with complete frontmatter passes.
- It does not enforce human review. The digest below makes review easier; nothing forces it.
- `git commit --no-verify` skips the hook. This is a guard against error and drift by cooperating
  agents. Against an adversary it is no protection at all; that needs server-side checks, which a
  personal vault does not warrant.
- Prompt injection through ingested content is handled upstream: in the source system,
  untrusted captures are stored as evidence and never executed as instructions.

## The review digest

`scripts/review-digest.ps1` lists everything since the last `reviewed` tag: the commits, with
`[destructive]` ones called out, the lines added to `meta/changelog.md`, and a diffstat. `-Mark`
moves the tag. It summarises what changed; it does not show every changed page. I moved to this
from reading each commit when several agent sessions started committing at the same time and
per-commit review stopped happening.

## Run the tests

```powershell
./test.ps1
```

Builds a throwaway git repo from `sample-vault/` and checks the gate's verdict for eight
representative cases:

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

The script exits 1 if any case fails, and the same script runs in GitHub Actions on every push.

To use it on a real vault: copy `scripts/` in and `hooks/commit-msg` to `.git/hooks/`.

## Why these rules

Each one follows something that went wrong in the source vault:

- A readiness score was copied onto a second page. The original was corrected later and the copy
  kept being read for weeks. The changelog requirement exists so that a change to a claim page
  shows up in one place a person actually reads.
- A directory list was copied into a config file that every session read and none wrote. A new
  directory appeared and the list stayed wrong for six weeks. The `area` field is checked against
  the directory the file is in for the same reason: a stated fact gets compared with the
  filesystem before it is believed.
- An agent reported a task complete when it was not, and a green uptime monitor once hid a dead
  service (the port listened; the app was gone). That is why `test.ps1` builds a real repo and runs
  the real hook; the functions are never tested in isolation.

## Design notes

- Review in batches, because per-commit review stopped happening once several
  sessions were committing concurrently.
- Git as the record. It already keeps history, authorship metadata and diffs in a format that fits
  a markdown vault. Its history can be rewritten, and the workflow still needs review and
  maintenance.
- No model in the hook. A commit-time check has to give the same answer every time and finish at
  once. A model-based reviewer would do neither, and it could be argued with.

## Authorship

Claude Code produced much of the implementation; I defined the behaviour and acceptance criteria,
reviewed what it produced against those, and owned testing and deployment.
