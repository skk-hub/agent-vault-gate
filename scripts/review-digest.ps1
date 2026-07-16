# Batch review: everything since the 'reviewed' tag. Read the changelog, not the diffs.
# Usage: scripts/review-digest.ps1          -> show the digest
#        scripts/review-digest.ps1 -Mark    -> move the tag to HEAD (done reviewing)
param([switch]$Mark)

$tag = 'reviewed'
if (-not (git tag -l $tag)) {
  git tag $tag
  "Created '$tag' tag at HEAD — the next run shows everything after this point."
  return
}
if ($Mark) {
  git tag -f $tag HEAD | Out-Null
  "Reviewed through $(git log -1 --format='%h (%s)')."
  return
}

$n = [int](git rev-list --count "$tag..HEAD")
if ($n -eq 0) { "Nothing new since the last review."; return }

"== $n commit(s) since last review =="
git log "$tag..HEAD" --reverse --format='%h  %cd  %s' --date=format:'%m-%d %H:%M'

$destr = git log "$tag..HEAD" --format='%h  %s' | Where-Object { $_ -match '\[destructive\]' }
"`n== destructive commits (read these line-by-line) =="
if ($destr) { $destr } else { "none" }

"`n== changelog additions (the human-readable review surface) =="
git diff "$tag..HEAD" -- meta/changelog.md | Where-Object { $_ -match '^\+[^+]' } | ForEach-Object { $_.Substring(1) }

"`n== diffstat =="
git diff --stat "$tag..HEAD"

"`nDone reviewing? scripts/review-digest.ps1 -Mark"
