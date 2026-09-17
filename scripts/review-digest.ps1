# Batch review: everything since the 'reviewed' tag.
#   scripts/review-digest.ps1                      show the digest; it ends with the hash it covered
#   scripts/review-digest.ps1 -Mark -Through <hash> move the tag to that hash (done reviewing)
# Marking needs the hash the digest printed, so a commit that landed after you read the digest
# cannot be marked reviewed by accident.
param([switch]$Mark, [string]$Through)
$ErrorActionPreference = 'Stop'

function Invoke-Git([string[]]$GitArgs, [int[]]$Ok = @(0)) {
  $ErrorActionPreference = 'Continue'
  $output = & git -c core.quotepath=false @GitArgs 2>$null
  if ($LASTEXITCODE -notin $Ok) { throw "git $($GitArgs -join ' ') failed with exit $LASTEXITCODE" }
  return $output
}

$tag = 'reviewed'
if ($Mark) {
  if (-not $Through) { throw '-Mark needs -Through <hash>, the hash the digest printed.' }
  $hash = (Invoke-Git @('rev-parse', '--verify', "$Through^{commit}")).Trim()
  Invoke-Git @('tag', '-f', $tag, $hash) | Out-Null
  "Reviewed through $(Invoke-Git @('log', '-1', '--format=%h (%s)', $hash))."
  return
}

if (-not (Invoke-Git @('tag', '-l', $tag))) {
  Invoke-Git @('tag', $tag) | Out-Null
  "Created the '$tag' tag at HEAD. Nothing before this point is reviewed by this tool; the next run shows everything after it."
  return
}

& git merge-base --is-ancestor "refs/tags/$tag" HEAD 2>$null
if ($LASTEXITCODE -ne 0) { throw "'$tag' is not an ancestor of HEAD, so '$tag..HEAD' would be an ambiguous range. Refusing." }

$head = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
$range = "$tag..$head"
$n = [int](Invoke-Git @('rev-list', '--count', $range))
if ($n -eq 0) { 'Nothing new since the last review.'; return }

"== $n commit(s) since last review =="
Invoke-Git @('log', $range, '--reverse', '--format=%h  %cd  %s', '--date=format:%m-%d %H:%M')

# Same rule as the gate: the marker counts only when it opens the subject.
$destructiveCommits = @(Invoke-Git @('log', $range, '--format=%h%x09%s') | Where-Object { ($_ -split "`t", 2)[1] -match '^\[destructive\]' })
"`n== destructive commits (read these line by line) =="
if ($destructiveCommits) { $destructiveCommits -replace "`t", '  ' } else { 'none' }

# Every line added to the changelog by any commit in the range, in order. Reading the commits
# rather than diffing the endpoints means an entry that was added and then removed still shows up.
"`n== changelog additions =="
Invoke-Git @('log', $range, '--reverse', '-p', '--format=', '--', ':(top)meta/changelog.md') | Where-Object { $_ -match '^\+[^+]' } | ForEach-Object { $_.Substring(1) }

"`n== diffstat =="
Invoke-Git @('diff', '--stat', $range)

"`nDone reviewing? scripts/review-digest.ps1 -Mark -Through $head"
