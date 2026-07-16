# Vault commit gate — called by .git/hooks/commit-msg with the message file path.
# Mechanical checks only; content review happens in the batch digest (scripts/review-digest.ps1).
# ponytail: line-level claim rewrites pass as "additive" — the digest catches those; the gate
# only hard-blocks the catastrophic shapes (raw/ tampering, file deletion, missing conventions).
param([string]$MsgFile)

$repo = (git rev-parse --show-toplevel).Trim()
$msg = if ($MsgFile -and (Test-Path $MsgFile)) { Get-Content $MsgFile -Raw } else { '' }
# subject line only — a body that merely *mentions* the marker is not an override
$destructive = ($msg -split "`r?`n")[0] -match '\[destructive\]'
$fail = [System.Collections.Generic.List[string]]::new()

$staged = git diff --cached --name-status --no-renames |
  ForEach-Object { $s, $p = $_ -split "`t", 2; [pscustomobject]@{ Status = $s; Path = $p } }
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
Get-ChildItem "$repo\areas", "$repo\wiki", "$repo\meta" -Recurse -Filter *.md | ForEach-Object {
  [void]$targets.Add($_.BaseName)
  $t = Get-Content $_.FullName -TotalCount 3 | Where-Object { $_ -match '^title:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() }
  if ($t) { [void]$targets.Add($t) }
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
