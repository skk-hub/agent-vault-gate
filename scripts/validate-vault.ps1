# Vault commit gate. hooks/commit-msg runs it with the commit-message file as the argument.
# It checks the shape of what is staged and nothing else; content review happens later in
# scripts/review-digest.ps1. Exit 0 = commit allowed, 1 = blocked, 2 = the gate itself failed.
param([string]$MsgFile)
$ErrorActionPreference = 'Stop'

# Every git call goes through here so a failing git command stops the gate instead of letting the
# commit through on empty output. Exit codes listed in -Ok are not failures (git grep exits 1 on
# no match).
function Invoke-Git([string[]]$GitArgs, [int[]]$Ok = @(0)) {
  $ErrorActionPreference = 'Continue'
  $output = & git -c core.quotepath=false @GitArgs 2>$null
  if ($LASTEXITCODE -notin $Ok) { throw "git $($GitArgs -join ' ') failed with exit $LASTEXITCODE" }
  return $output
}

# Parses the frontmatter block at the top of a page. Returns $null when there is no block or it is
# never closed, otherwise a hashtable of field -> value with comments and surrounding quotes removed.
# This same function decides both whether a page is valid and what its title is, so the two can't
# disagree.
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

try {
  $msg = if ($MsgFile -and (Test-Path -LiteralPath $MsgFile)) { Get-Content -LiteralPath $MsgFile -Raw } else { '' }
  # The override marker has to open the subject line. A subject that merely mentions it does not count.
  $destructive = ($msg -split "`r?`n")[0].TrimStart() -match '^\[destructive\]'
  $fail = [System.Collections.Generic.List[string]]::new()

  # NUL-delimited status/path pairs, with git's own quoting of non-ASCII paths switched off, so a
  # filename with an accent, a quote or a newline reaches the checks below intact.
  $fields = ((Invoke-Git @('diff', '--cached', '--name-status', '-z', '--no-renames')) -join "`n") -split "`0" | Where-Object { $_ -ne '' }
  $staged = @(for ($i = 0; $i -lt $fields.Count - 1; $i += 2) {
    [pscustomobject]@{ Status = $fields[$i]; Path = $fields[$i + 1] }
  })
  if (-not $staged) { exit 0 }

  # raw/ only grows; deleting anything needs the marker.
  foreach ($f in $staged) {
    if ($f.Path -like 'raw/*' -and $f.Status -ne 'A' -and -not $destructive) {
      $fail.Add("raw/ is append-only: '$($f.Path)' is $($f.Status). New information goes in a new dated file. Override only with a [destructive] subject.")
    }
    if ($f.Status -eq 'D' -and -not $destructive) {
      $fail.Add("deletion of '$($f.Path)' requires a [destructive] subject.")
    }
    if ($f.Status -eq 'T' -and $f.Path -match '^(areas|wiki|meta)/.*\.md$') {
      $fail.Add("$($f.Path): type changes to markdown pages are not allowed.")
    }
  }

  # Claim pages: complete frontmatter, and the area field agrees with the directory.
  $exempt = '_handoff.md', '_area.md', '_router.md', '_claude-packet.md'
  $required = 'title', 'type', 'area', 'created', 'updated', 'review_by', 'sources', 'status'
  $wikiPages = @($staged | Where-Object { $_.Status -in 'A', 'M' -and $_.Path -match '^areas/.*\.md$' -and (Split-Path $_.Path -Leaf) -notin $exempt })
  foreach ($f in $wikiPages) {
    $fm = Read-Frontmatter @(Invoke-Git @('show', ":$($f.Path)"))
    if ($null -eq $fm) { $fail.Add("$($f.Path): frontmatter is missing or has no closing delimiter."); continue }
    foreach ($field in $required) {
      if ($fm[$field] -in $null, '', '[]', '~', 'null') { $fail.Add("$($f.Path): frontmatter missing '$field'.") }
    }
    if ($f.Path -notmatch '^areas/([^/]+)/.+\.md$') {
      $fail.Add("$($f.Path): claim pages must live under areas/<area>/.")
    } elseif ($fm['area'] -and $fm['area'] -cne $Matches[1]) {
      $fail.Add("$($f.Path): area '$($fm['area'])' does not match directory '$($Matches[1])'.")
    }
  }

  # A claim-page change has to come with a changelog entry in the same commit. The gate checks that
  # the changelog file was added or modified; it does not read the entry.
  $changelogChanged = $staged | Where-Object { $_.Path -eq 'meta/changelog.md' -and $_.Status -in 'A', 'M' }
  if ($wikiPages -and -not $changelogChanged) {
    $fail.Add('claim page changes staged without an added or modified meta/changelog.md.')
  }

  # Every [[wikilink]] in a staged page must point at a page in the index, by filename or by
  # frontmatter title. The index, not the working tree: an unstaged file must not satisfy a link.
  $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in @(Invoke-Git @('ls-files', '--', 'areas', 'wiki', 'meta'))) {
    if ($p -match '\.md$') { [void]$targets.Add([System.IO.Path]::GetFileNameWithoutExtension($p)) }
  }
  # One git call for every '---' and 'title:' line in the index; a title counts only inside the
  # opening frontmatter block. ponytail: the path is split on the first ':', so a path containing
  # ':' would misparse; switch to `git grep -z` if that ever happens.
  $open = @{}
  foreach ($hit in @(Invoke-Git @('grep', '--cached', '-n', '-e', '^---$', '-e', '^title:', '--', 'areas', 'wiki', 'meta') -Ok 0, 1)) {
    if ($hit -notmatch '^(.+?):(\d+):(.*)$') { continue }
    $path, $line, $text = $Matches[1], [int]$Matches[2], $Matches[3]
    if ($path -notmatch '\.md$') { continue }
    if (-not $open.ContainsKey($path)) { $open[$path] = 0 }   # 0 = before block, 1 = inside, 2 = closed
    if ($text -eq '---') {
      if ($open[$path] -eq 0 -and $line -eq 1) { $open[$path] = 1 } elseif ($open[$path] -eq 1) { $open[$path] = 2 }
    } elseif ($open[$path] -eq 1 -and $text -match '^title:\s*(.*)$') {
      $t = ($Matches[1] -replace '(^|\s+)#.*$', '').Trim().Trim('"', "'")
      if ($t) { [void]$targets.Add($t) }
    }
  }
  foreach ($f in $staged | Where-Object { $_.Status -in 'A', 'M' -and $_.Path -match '^(areas|wiki|meta)/.*\.md$' }) {
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
