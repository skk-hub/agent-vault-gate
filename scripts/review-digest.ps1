# Batch review: everything since the 'reviewed' tag.
#   scripts/review-digest.ps1                      show the digest; it ends with the hash it covered
#   scripts/review-digest.ps1 -Mark -Through <hash> move the tag to that hash (done reviewing)
# -Through has to be the full hash the digest printed, and that commit has to sit between the tag
# and HEAD. HEAD, a short hash or a branch name is refused, so a commit that landed after you read
# the digest cannot be marked reviewed by accident.
param([switch]$Mark, [string]$Through)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/git.ps1"

$tag = 'reviewed'
if ($Mark) {
  if ($Through -notmatch '^[0-9a-f]{40}$') { throw '-Mark needs -Through <hash>: the full 40-character hash the digest printed.' }
  Invoke-Git @('merge-base', '--is-ancestor', "refs/tags/$tag", $Through) -Ok 0, 1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$Through is not after the '$tag' tag." }
  Invoke-Git @('merge-base', '--is-ancestor', $Through, 'HEAD') -Ok 0, 1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "$Through is not an ancestor of HEAD." }
  Invoke-Git @('tag', '-f', $tag, $Through) | Out-Null
  "Reviewed through $(Invoke-Git @('log', '-1', '--format=%h (%s)', $Through))."
  return
}

if (-not (Invoke-Git @('tag', '-l', $tag))) {
  Invoke-Git @('tag', $tag) | Out-Null
  "Created the '$tag' tag at HEAD. Nothing before this point is reviewed by this tool; the next run shows everything after it."
  return
}

Invoke-Git @('merge-base', '--is-ancestor', "refs/tags/$tag", 'HEAD') -Ok 0, 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "'$tag' is not an ancestor of HEAD, so '$tag..HEAD' would be an ambiguous range. Refusing." }

$head = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
$range = "$tag..$head"
$n = [int](Invoke-Git @('rev-list', '--count', $range))
if ($n -eq 0) { 'Nothing new since the last review.'; return }

"== $n commit(s) since last review =="
Invoke-Git @('log', $range, '--reverse', '--format=%h  %cd  %s', '--date=format:%m-%d %H:%M')

# Same rule as the gate: the marker counts only when it opens the trimmed subject.
$destructiveCommits = @(Invoke-Git @('log', $range, '--format=%h%x09%s') | Where-Object { ($_ -split "`t", 2)[1].Trim() -match '^\[destructive\]' })
"`n== destructive commits (read these line by line) =="
if ($destructiveCommits) { $destructiveCommits -replace "`t", '  ' } else { 'none' }

# Every line the range added to the changelog, walking the first-parent chain so a merge shows
# what it actually brought in (including a resolution-only change). Added lines are marked with
# '>' instead of '+' so that a blank addition, or one starting with '+', is kept and the '+++'
# diff header is not.
"`n== changelog additions =="
Invoke-Git @('log', $range, '--reverse', '--first-parent', '--diff-merges=first-parent', '-p', '--format=', '--output-indicator-new=>', '--', ':(top)meta/changelog.md') | Where-Object { $_ -match '^>' } | ForEach-Object { $_.Substring(1) }

"`n== diffstat =="
Invoke-Git @('diff', '--stat', $range)

"`nDone reviewing? scripts/review-digest.ps1 -Mark -Through $head"
