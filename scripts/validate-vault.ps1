# Vault commit gate — called by .git/hooks/commit-msg with the message file path.
# Mechanical checks only; content review happens in the batch digest (scripts/review-digest.ps1).
# ponytail: line-level claim rewrites pass as "additive" — the digest catches those; the gate
# only hard-blocks the catastrophic shapes (raw/ tampering, file deletion, missing conventions).
param([string]$MsgFile)

$repo = (git rev-parse --show-toplevel).Trim()
$msg = if ($MsgFile -and (Test-Path $MsgFile)) { Get-Content $MsgFile -Raw } else { '' }
# Subject line only, and ANCHORED: a body that mentions the marker is not an override, and
# neither is a subject that merely talks about it ("document what [destructive] means").
$destructive = ($msg -split "`r?`n")[0].TrimStart() -match '^\[destructive\]'
$fail = [System.Collections.Generic.List[string]]::new()

# -z + quotepath=false, because git otherwise QUOTES any path containing a non-ASCII byte:
# raw/note-café.md arrives as "raw/note-caf\303\251.md", and that leading double-quote makes
# every path test below miss — one accented filename would skip raw/, frontmatter, area,
# changelog and wikilink enforcement in one go. -z also survives quotes and newlines in names.
$fields = ((git -c core.quotepath=false diff --cached --name-status -z --no-renames) -join "`n") -split "`0" |
  Where-Object { $_ -ne '' }
$staged = @(for ($i = 0; $i -lt $fields.Count - 1; $i += 2) {
  [pscustomobject]@{ Status = $fields[$i]; Path = $fields[$i + 1] }
})
if (-not $staged) { exit 0 }

# --- raw/ is append-only; deletions anywhere are destructive ---
foreach ($f in $staged) {
  if ($f.Path -like 'raw/*' -and $f.Status -ne 'A' -and -not $destructive) {
    $fail.Add("raw/ is append-only: '$($f.Path)' is $($f.Status). New info = a NEW dated file. Override only with [destructive] in the commit message.")
  }
  if ($f.Status -eq 'D' -and -not $destructive) {
    $fail.Add("deletion of '$($f.Path)' requires [destructive] in the commit message (and line-by-line human review).")
  }
}

# --- wiki pages: frontmatter complete, area matches directory ---
$exempt = '_handoff.md', '_area.md', '_router.md', '_claude-packet.md'
$wikiPages = $staged | Where-Object { $_.Status -in 'A', 'M' -and $_.Path -match '^areas/.*\.md$' -and (Split-Path $_.Path -Leaf) -notin $exempt }
foreach ($f in $wikiPages) {
  $lines = git show ":$($f.Path)" 2>$null
  if (-not $lines -or $lines[0] -ne '---') { $fail.Add("$($f.Path): missing frontmatter."); continue }
  $fm = @{}
  foreach ($line in $lines[1..([Math]::Min(30, $lines.Count - 1))]) {
    if ($line -eq '---') { break }
    if ($line -match '^(\w+):\s*(.*)$') { $fm[$Matches[1]] = $Matches[2].Trim() }
  }
  foreach ($field in 'title', 'type', 'area', 'created', 'updated', 'review_by', 'sources', 'status') {
    if (-not $fm[$field] -or $fm[$field] -in '[]', '') { $fail.Add("$($f.Path): frontmatter missing '$field'.") }
  }
  if ($fm['area'] -and $f.Path -match '^areas/([^/]+)/' -and $fm['area'] -ne $Matches[1]) {
    $fail.Add("$($f.Path): area '$($fm['area'])' does not match directory '$($Matches[1])'.")
  }
}

# --- wiki edits must carry a changelog entry ---
if ($wikiPages -and -not ($staged | Where-Object Path -eq 'meta/changelog.md')) {
  $fail.Add("wiki page changes staged without a meta/changelog.md entry.")
}

# --- wikilinks in staged files must resolve (the #1 observed rot) ---
$targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# Targets come from the INDEX, not the working tree. Reading the filesystem let an UNSTAGED
# file satisfy a link, so the commit landed with a wikilink resolving to nothing.
foreach ($p in (git -c core.quotepath=false ls-files -- areas wiki meta 2>$null)) {
  if ($p -match '\.md$') { [void]$targets.Add([System.IO.Path]::GetFileNameWithoutExtension($p)) }
}
# One git call for every frontmatter title in the index; the line-number guard keeps this to
# frontmatter rather than any 'title:' in prose.
foreach ($line in (git grep --cached -n -h -e '^title:' -- areas wiki meta 2>$null)) {
  if ($line -match '^[1-3]:title:\s*(.+)$') { [void]$targets.Add($Matches[1].Trim()) }
}
foreach ($f in $staged | Where-Object { $_.Status -in 'A', 'M' -and $_.Path -match '^(areas|wiki|meta)/.*\.md$' }) {
  $txt = (git show ":$($f.Path)" 2>$null) -join "`n"
  $txt = $txt -replace '`[^`]*`', ''   # backtick-quoted links are illustrative, not links
  foreach ($m in [regex]::Matches($txt, '\[\[([^\]\|#]+)(#[^\]\|]*)?(\|[^\]]*)?\]\]')) {
    $t = $m.Groups[1].Value.Trim() -replace '\s+', ' '
    if ($t -and -not $targets.Contains($t)) { $fail.Add("$($f.Path): broken wikilink [[$t]] — no page with that filename or title.") }
  }
}

if ($fail.Count) {
  Write-Host "VAULT GATE FAILED — fix and re-commit (bypass: --no-verify, but don't):" -ForegroundColor Red
  $fail | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
  exit 1
}
exit 0
