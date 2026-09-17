# Vault commit gate. hooks/commit-msg runs it with the commit-message file as the argument.
# It checks the shape of what is staged and nothing else; content review happens later in
# scripts/review-digest.ps1. Exit 0 = commit allowed, 1 = blocked, 2 = the gate itself failed.
param([string]$MsgFile)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/git.ps1"

# Parses the frontmatter block at the top of a page. Returns $null when there is no block or it is
# never closed, otherwise a hashtable of field -> value with comments and surrounding quotes removed.
# It is the only frontmatter parser: it decides whether a staged page is valid and, run over the
# index, which titles a [[wikilink]] can point at.
function Read-Frontmatter([string[]]$Lines) {
  if (-not $Lines -or $Lines[0] -ne '---') { return $null }
  $close = -1
  for ($i = 1; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -eq '---') { $close = $i; break } }
  if ($close -lt 1) { return $null }
  $fm = @{}
  for ($i = 1; $i -lt $close; $i++) {
    if ($Lines[$i] -match '^(\w+):\s*(.*)$') {
      $fm[$Matches[1]] = ($Matches[2] -replace '(^|\s+)#.*$', '').Trim().Trim('"', "'")
    }
  }
  return $fm
}

# Paths are tested with ordinal string operations, not regexes: a path can contain a newline, and
# '.' in a regex would not match it.
function Test-Under([string]$Path, [string[]]$Dirs) { foreach ($d in $Dirs) { if ($Path.StartsWith("$d/")) { return $true } } ; return $false }
function Test-Page([string]$Path) { return $Path.EndsWith('.md') -and (Test-Under $Path 'areas', 'wiki', 'meta') }

try {
  $msg = if ($MsgFile -and (Test-Path -LiteralPath $MsgFile)) { [string](Get-Content -LiteralPath $MsgFile -Raw) } else { '' }
  # The override marker has to open the subject line. A subject that merely mentions it does not
  # count. review-digest.ps1 applies the same test to the same trimmed subject.
  $destructive = ($msg -split "`r?`n")[0].Trim() -match '^\[destructive\]'
  $fail = [System.Collections.Generic.List[string]]::new()

  # Staged entries as `:oldmode newmode oldsha newsha status\0path\0`, with git's own quoting of
  # unusual paths switched off, so a filename with an accent, a quote or a newline reaches the
  # checks intact. The mode is what tells a symlink from a file.
  $fields = ((Invoke-Git @('diff', '--cached', '--raw', '-z', '--no-renames')) -join "`n") -split "`0" | Where-Object { $_ -ne '' }
  $staged = @(for ($i = 0; $i -lt $fields.Count - 1; $i += 2) {
    $meta = $fields[$i].TrimStart(':') -split ' '
    [pscustomobject]@{ Mode = $meta[1]; Status = $meta[4]; Path = $fields[$i + 1] }
  })
  if (-not $staged) { exit 0 }

  foreach ($f in $staged) {
    # raw/ only grows; deleting anything needs the marker.
    if ((Test-Under $f.Path 'raw') -and $f.Status -ne 'A' -and -not $destructive) {
      $fail.Add("raw/ is append-only: '$($f.Path)' is $($f.Status). New information goes in a new dated file. Override only with a [destructive] subject.")
    }
    if ($f.Status -eq 'D' -and -not $destructive) {
      $fail.Add("deletion of '$($f.Path)' requires a [destructive] subject.")
    }
    # A symlink is never a page or an evidence file, whether it is new or replaces one.
    if ($f.Mode -eq '120000' -and ((Test-Under $f.Path 'raw') -or (Test-Page $f.Path))) {
      $fail.Add("$($f.Path): symlinks are not allowed under raw/ or as markdown pages.")
    }
  }

  # Pages under areas/: the hierarchy rule applies to every one of them, the frontmatter rules to
  # every one except four housekeeping filenames.
  $exempt = '_handoff.md', '_area.md', '_router.md', '_claude-packet.md'
  $required = 'title', 'type', 'area', 'created', 'updated', 'review_by', 'sources', 'status'
  $claimPages = [System.Collections.Generic.List[object]]::new()
  foreach ($f in $staged | Where-Object { $_.Status -in 'A', 'M' -and $_.Path.EndsWith('.md') -and (Test-Under $_.Path 'areas') }) {
    $parts = $f.Path.Split('/')
    if ($parts.Count -lt 3) { $fail.Add("$($f.Path): claim pages must live under areas/<area>/."); continue }
    if ($parts[-1] -in $exempt) { continue }
    $claimPages.Add($f)
    $fm = Read-Frontmatter @(Invoke-Git @('show', ":$($f.Path)"))
    if ($null -eq $fm) { $fail.Add("$($f.Path): frontmatter is missing or has no closing delimiter."); continue }
    foreach ($field in $required) {
      if ($fm[$field] -in $null, '', '[]', '~', 'null') { $fail.Add("$($f.Path): frontmatter missing '$field'.") }
    }
    if ($fm['area'] -and $fm['area'] -cne $parts[1]) {
      $fail.Add("$($f.Path): area '$($fm['area'])' does not match directory '$($parts[1])'.")
    }
  }

  # A claim-page change has to come with a changelog entry in the same commit. The gate checks that
  # the changelog file was added or modified; it does not read the entry.
  $changelogChanged = $staged | Where-Object { $_.Path -eq 'meta/changelog.md' -and $_.Status -in 'A', 'M' }
  if ($claimPages.Count -and -not $changelogChanged) {
    $fail.Add('claim page changes staged without an added or modified meta/changelog.md.')
  }

  # Every [[wikilink]] in a staged page must point at a page in the index, by filename or by
  # frontmatter title. The index, not the working tree: an unstaged file must not satisfy a link.
  $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in ((Invoke-Git @('ls-files', '-z', '--', 'areas', 'wiki', 'meta')) -join "`n") -split "`0") {
    if (Test-Page $p) { [void]$targets.Add([System.IO.Path]::GetFileNameWithoutExtension($p)) }
  }
  # One git call reads every line of every indexed page (`path\0lineno\0text`); the lines are
  # grouped by path and handed to the same Read-Frontmatter that validates staged pages.
  $lines = @{}
  foreach ($hit in @(Invoke-Git @('grep', '--cached', '-z', '-n', '-e', '^', '--', 'areas', 'wiki', 'meta') -Ok 0, 1)) {
    $path, $lineNo, $text = $hit -split "`0", 3
    if ($null -eq $text -or -not (Test-Page $path)) { continue }
    if (-not $lines.ContainsKey($path)) { $lines[$path] = [System.Collections.Generic.List[string]]::new() }
    $lines[$path].Add($text)
  }
  foreach ($path in $lines.Keys) {
    $fm = Read-Frontmatter $lines[$path].ToArray()
    if ($fm -and $fm['title']) { [void]$targets.Add($fm['title']) }
  }
  foreach ($f in $staged | Where-Object { $_.Status -in 'A', 'M' -and (Test-Page $_.Path) }) {
    $txt = (Invoke-Git @('show', ":$($f.Path)")) -join "`n"
    $txt = $txt -replace '`[^`]*`', ''   # a link inside backticks is being quoted, not made
    foreach ($m in [regex]::Matches($txt, '\[\[([^\]\|#]+)(#[^\]\|]*)?(\|[^\]]*)?\]\]')) {
      $t = $m.Groups[1].Value.Trim() -replace '\s+', ' '
      if ($t -and -not $targets.Contains($t)) { $fail.Add("$($f.Path): broken wikilink [[$t]]: no page with that filename or title.") }
    }
  }

  if ($fail.Count) {
    Write-Host 'VAULT GATE FAILED. Fix and re-commit (bypass: --no-verify, but do not):' -ForegroundColor Red
    $fail | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" }
    exit 1
  }
  exit 0
}
catch {
  Write-Host "VAULT GATE ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 2
}
