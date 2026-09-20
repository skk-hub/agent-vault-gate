# agent-vault-gate

A `commit-msg` hook that checks a few conventions in a markdown vault before a commit lands, plus
a digest for reviewing commits in batches. Extracted from a private personal knowledge base that
several AI agents write to (Claude Code sessions, a headless ingest job, an always-on
orchestrator). The vault itself stays private; this repo holds the hook, the digest script, a
synthetic sample vault and a test script.

## What the hook checks

`hooks/commit-msg` runs `scripts/validate-vault.ps1` against the staged files of the commit:

- A file under `raw/` can be added. Editing or deleting one is blocked unless the commit subject
  starts with `[destructive]`. A subject that merely mentions the marker does not count.
- Deleting any file is blocked without that same subject prefix.
- Anything staged under `raw/`, `areas/`, `wiki/` or `meta/` whose mode is not a regular file is
  blocked, new or replacing a file: that covers a symlink and a gitlink pointing at another
  repository.
- A markdown page directly under `areas/` is rejected, whatever its name. Any staged page under
  `areas/<area>/` (four housekeeping filenames excepted) has to open with a closed frontmatter
  block carrying eight nonempty fields: `title`, `type`, `area`, `created`, `updated`,
  `review_by`, `sources`, `status`. Its `area` value has to equal the directory name. A page is
  recognised by its path, so the extension matches regardless of case and a type change is
  checked like any other change.
- If any such page changed, `meta/changelog.md` has to be added or modified in the same commit.
  The hook checks the file changed; it does not read the entry.
- Every `[[wikilink]]` in a staged markdown page under `areas/`, `wiki/` or `meta/` has to resolve
  to a page in the index, by filename or by the `title` inside its frontmatter block. Targets come
  from the index, so a file that exists only in the working tree does not satisfy a link. Links in
  files that were not staged are not checked, so a `[destructive]` deletion can leave links
  elsewhere broken.

Staged paths and the index are read NUL-delimited with git's path quoting off, so a filename with
an accent, a quote or a newline goes through the same checks (the accent case runs everywhere; the
quote and newline cases run on the Linux job, since Windows does not allow those filenames). One
function parses frontmatter, both to validate a staged page and to collect the titles a link can
point at, so `Title:` or a CRLF page reads the same on both sides. Every git call is checked for
its exit code; if git fails, the gate exits 2 with git's own error and the commit does not go
through.

## What it does not do

- It checks shape, and only shape. A wrong claim with complete frontmatter passes.
- It does not enforce human review. The digest below makes review easier; nothing forces it.
- `git commit --no-verify` skips the hook. This is a guard against error and drift by cooperating
  agents. Against an adversary it is no protection at all; that needs server-side checks, which a
  personal vault does not warrant.
- It does nothing about prompt injection through ingested content. That trust boundary belongs to
  whatever ingests the content, upstream of any commit.

## The review digest

`scripts/review-digest.ps1` lists everything since the local `reviewed` tag: the commits, with
`[destructive]` ones called out (same trimmed-subject test as the gate), every line the range
added to `meta/changelog.md` along the first-parent chain (so a merge shows what it brought in,
including a resolution-only edit), and a diffstat. It ends with the hash it covered, and
`-Mark -Through <that hash>` moves the tag there. `-Through` has to be that full hash and has to
sit between the tag and HEAD; `HEAD`, a short hash or a branch name is refused, so a commit that
landed while you were reading cannot be marked reviewed by accident. The first run creates the
tag at HEAD; nothing before that point is reviewed by this tool. If the tag is not an ancestor of
HEAD the script refuses rather than print an ambiguous range. It summarises what changed; it does
not show every changed page. I moved to this from reading each commit when several agent sessions
started committing at the same time and per-commit review stopped happening.

## Run the tests

```powershell
./test.ps1                      # validator under PowerShell 7
./test.ps1 -Runtime powershell  # validator under Windows PowerShell 5.1
```

The script builds a throwaway git repo from `sample-vault/` and checks the gate's exit code and
its diagnostic for each rule above and each way past it that review found (the non-ASCII, quoted
and newline filenames, the mid-subject and leading-space markers, the unstaged link target, the
deleted changelog, the unclosed frontmatter, the housekeeping name in the wrong place, the two
symlink shapes, the three gitlink shapes, the uppercase `.MD` extension, the `Title:` CRLF page),
plus git failing under the gate. It then copies
`hooks/commit-msg` into that repo and makes two real commits through it, one that has to be
blocked and one that has to pass, and finally runs the digest through create, list (destructive
commit, blank and `+`-prefixed changelog lines, a merge resolution), the three refused `-Through`
forms, mark, empty, and a tag off the branch. Every setup step is exit-code checked and a
scenario with nothing staged fails rather than passing on an empty index. It exits 1 if anything
fails. GitHub Actions runs it on every push under PowerShell 7 and 5.1 on Windows and PowerShell 7
on Ubuntu.

To use it on a real vault: copy `scripts/` in and `hooks/commit-msg` to `.git/hooks/`, keeping
the file executable.

## Why these rules

Each one follows something that went wrong in the source vault:

- A readiness score was copied onto a second page. The original was corrected later and the copy
  kept being read for weeks. The changelog requirement exists so that a change to a claim page
  shows up in one place a person actually reads.
- A directory list was copied into a config file that every session read and none wrote. A new
  directory appeared and the list stayed wrong for six weeks. The `area` field is checked against
  the directory the file is in for the same reason: a stated fact gets compared with the
  filesystem before it is believed.

## Design notes

- Review in batches, because per-commit review stopped happening once several sessions were
  committing concurrently.
- Git as the record. It already keeps history, authorship metadata and diffs in a format that fits
  a markdown vault. Its history can be rewritten, and the workflow still needs review and
  maintenance.
- No model in the hook. A commit-time check has to give the same answer every time and finish at
  once. A model-based reviewer would do neither, and it could be argued with.

## Authorship

Claude Code produced much of the implementation; I defined the behaviour and acceptance criteria,
reviewed what it produced against those, and owned testing and deployment. The current version
followed two adversarial reviews of earlier public ones, each of which found bypasses that are
now scenarios in `test.ps1`.

## License

MIT, see [LICENSE](LICENSE).
