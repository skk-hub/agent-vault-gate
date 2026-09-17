# test.ps1: builds a throwaway git repo from sample-vault/ and checks the gate's exit code AND its
# diagnostic for each scenario, then installs the hook and makes real commits through it, then
# exercises the digest. No frameworks, no dependencies.
#   ./test.ps1                      run the validator under pwsh (PowerShell 7)
#   ./test.ps1 -Runtime powershell  run it under Windows PowerShell 5.1
param([ValidateSet('pwsh', 'powershell')][string]$Runtime = 'pwsh')
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$ps = (Get-Command $Runtime -ErrorAction Stop).Source
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vault-gate-test-$(Get-Random)"
$unix = [System.Environment]::OSVersion.Platform -eq 'Unix'
$script:failed = 0

# Test setup runs git through this so a failed setup step fails the scenario instead of running
# the gate against a half-built repo.
function G { & git @args; if ($LASTEXITCODE) { throw "setup: git $args failed with exit $LASTEXITCODE" } }

function New-TestVault {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory $work | Out-Null
    Copy-Item "$root/sample-vault/*" $work -Recurse
    New-Item -ItemType Directory "$work/scripts" | Out-Null
    Copy-Item "$root/scripts/*" "$work/scripts/"
    # A non-ASCII filename in the seed, because git quotes those paths unless told not to.
    [System.IO.File]::WriteAllText("$work/raw/note-2026-01-07-café-visit.md", "Bought seeds at the café.`n")
    Push-Location $work
    try {
        G init -q
        G config core.autocrlf false
        G config user.email test@test
        G config user.name test
        G add -A
        G commit -qm seed
    } finally { Pop-Location }
}

function Invoke-Gate([string]$subject) {
    $ErrorActionPreference = 'Continue'
    Set-Content -LiteralPath "$work/.msg" $subject
    $out = & $ps -NoProfile -File scripts/validate-vault.ps1 "$work/.msg" 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

function Report([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { Write-Host "PASS  $name" -ForegroundColor Green; return }
    $script:failed++
    Write-Host "FAIL  $name" -ForegroundColor Red
    $detail -split "`n" | ForEach-Object { Write-Host "      $_" }
}

# Stages the change (unless the scenario stages by hand), checks that something is actually
# staged, runs the validator, and checks both the exit code and, when given, that the diagnostic
# names the rule that fired.
function Assert-Gate([string]$name, [int]$expected, [scriptblock]$change, [string]$subject = 'routine ingest', [string]$reason = '', [switch]$ManualStage) {
    New-TestVault
    Push-Location $work
    try {
        & $change
        if (-not $ManualStage) { G add -A }
        & git diff --cached --quiet
        if ($LASTEXITCODE -eq 0) { throw "setup: nothing staged for '$name'" }
        $r = Invoke-Gate $subject
    } finally { Pop-Location }
    $ok = ($r.Code -eq $expected) -and ($reason -eq '' -or $r.Out -match $reason)
    Report $name $ok "expected exit $expected$(if ($reason) { " matching '$reason'" }), got $($r.Code):`n$($r.Out)"
}

function Invoke-Digest { $ErrorActionPreference = 'Continue'; & $ps -NoProfile -File scripts/review-digest.ps1 @args 2>&1 | Out-String }

$goodPage = @(
    '---', 'title: Compost Bin', 'type: entity', 'area: gardening', 'created: 2026-01-10', 'updated: 2026-01-10',
    'review_by: 2026-04-10', 'sources: [raw/note-2026-01-05-first-planting.md]', 'status: active', '---', '',
    '# Compost Bin', '', 'Behind the shed. Feeds the [[Tomato Bed]].'
) -join "`n"
$shedPage = $goodPage -replace 'title: Compost Bin', 'title: "Garden Shed"' -replace '# Compost Bin', '# Garden Shed'
$entry = '- 2026-01-10: Added [[Compost Bin]].'

try {
    Assert-Gate 'valid new page + changelog entry -> accepted' 0 {
        Set-Content areas/gardening/entities/compost-bin.md $goodPage
        Add-Content meta/changelog.md $entry
    }
    Assert-Gate 'frontmatter missing review_by -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace 'review_by: [^\n]+\n', '')
        Add-Content meta/changelog.md $entry
    } -reason "missing 'review_by'"
    Assert-Gate 'frontmatter field present but empty -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace 'sources: [^\n]+', 'sources: # none yet')
        Add-Content meta/changelog.md $entry
    } -reason "missing 'sources'"
    Assert-Gate 'frontmatter never closed -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace "status: active`n---", 'status: active')
        Add-Content meta/changelog.md $entry
    } -reason 'closing delimiter'
    Assert-Gate 'area field contradicts directory -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace 'area: gardening', 'area: cooking')
        Add-Content meta/changelog.md $entry
    } -reason 'does not match directory'
    Assert-Gate 'claim page directly under areas/ -> blocked' 1 {
        Set-Content areas/top.md $goodPage
        Add-Content meta/changelog.md $entry
    } -reason 'must live under'
    Assert-Gate 'housekeeping filename directly under areas/ -> still blocked' 1 {
        Set-Content areas/_area.md 'no frontmatter, exempt name, wrong place'
    } -reason 'must live under'
    Assert-Gate 'housekeeping filename inside an area, no frontmatter -> accepted' 0 {
        Set-Content areas/gardening/_area.md 'no frontmatter needed here'
    }
    Assert-Gate 'editing an evidence snapshot in raw/ -> blocked' 1 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Actually it was five plants.'
    } -reason 'append-only'
    Assert-Gate 'editing a raw/ file with a non-ASCII name -> blocked' 1 {
        Add-Content -LiteralPath 'raw/note-2026-01-07-café-visit.md' 'And a trowel.'
    } -reason 'append-only'
    if ($unix) {
        # Windows forbids these characters in filenames, so only the Linux job covers them.
        Assert-Gate 'editing a raw/ file with a quote in its name -> blocked' 1 {
            [System.IO.File]::WriteAllText("$work/raw/note-2026-01-09-`"quoted`".md", "one`n")
            G add -A
            G commit -qm 'seed quoted'
            [System.IO.File]::AppendAllText("$work/raw/note-2026-01-09-`"quoted`".md", "two`n")
        } -reason 'append-only'
        Assert-Gate 'editing a raw/ file with a newline in its name -> blocked' 1 {
            [System.IO.File]::WriteAllText("$work/raw/note-2026-01-09-two`nlines.md", "one`n")
            G add -A
            G commit -qm 'seed newline'
            [System.IO.File]::AppendAllText("$work/raw/note-2026-01-09-two`nlines.md", "two`n")
        } -reason 'append-only'
    }
    Assert-Gate 'same raw/ edit with [destructive] marker -> accepted (loud path)' 0 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Correction with human sign-off.'
    } -subject '[destructive] fix planting count in snapshot'
    Assert-Gate 'marker after leading spaces still opens the subject -> accepted' 0 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Correction with human sign-off.'
    } -subject '   [destructive] fix planting count in snapshot'
    Assert-Gate 'marker mentioned mid-subject is not an override -> blocked' 1 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Sneaky edit.'
    } -subject 'document what [destructive] means' -reason 'append-only'
    Assert-Gate 'deleting a page without [destructive] -> blocked' 1 {
        G rm -q areas/gardening/notes/watering-schedule.md
    } -reason 'requires a \[destructive\]'
    Assert-Gate 'turning a page into a symlink -> blocked' 1 {
        $blob = ('elsewhere.md' | git hash-object -w --stdin).Trim()
        G update-index --cacheinfo "120000,$blob,areas/gardening/entities/tomato-bed.md"
    } -reason 'symlinks are not allowed' -ManualStage
    Assert-Gate 'adding a symlink under raw/ -> blocked' 1 {
        $blob = ('/etc/hostname' | git hash-object -w --stdin).Trim()
        G update-index --add --cacheinfo "120000,$blob,raw/note-2026-01-09-link.md"
    } -reason 'symlinks are not allowed' -ManualStage
    Assert-Gate 'wiki edit without a changelog entry -> blocked' 1 {
        Add-Content areas/gardening/entities/tomato-bed.md 'Mulched 2026-01-12.'
    } -reason 'without an added or modified'
    Assert-Gate 'deleting the changelog does not count as a changelog entry -> blocked' 1 {
        Add-Content areas/gardening/entities/tomato-bed.md 'Mulched 2026-01-12.'
        G rm -q meta/changelog.md
    } -subject '[destructive] drop the changelog' -reason 'without an added or modified'
    Assert-Gate 'broken wikilink -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[No Such Page]]')
        Add-Content meta/changelog.md $entry
    } -reason 'broken wikilink'
    Assert-Gate 'wikilink satisfied only by an unstaged file -> blocked' 1 {
        Set-Content areas/gardening/entities/garden-shed.md $shedPage
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[Garden Shed]]')
        Add-Content meta/changelog.md $entry
        G add areas/gardening/entities/compost-bin.md meta/changelog.md
    } -reason 'broken wikilink' -ManualStage
    Assert-Gate 'wikilink to a quoted frontmatter title in the same commit -> accepted' 0 {
        Set-Content areas/gardening/entities/garden-shed.md $shedPage
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[Garden Shed]]')
        Add-Content meta/changelog.md $entry
    }
    Assert-Gate 'wikilink to a title written as Title: in a CRLF page -> accepted' 0 {
        [System.IO.File]::WriteAllText("$work/areas/gardening/entities/garden-shed.md", (($shedPage -replace 'title: "Garden Shed"', 'Title: Garden Shed') -replace "`n", "`r`n"))
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[Garden Shed]]')
        Add-Content meta/changelog.md $entry
    }

    # The gate itself failing (here: no repository) is exit 2, not a pass.
    $noRepo = Join-Path ([System.IO.Path]::GetTempPath()) "vault-gate-norepo-$(Get-Random)"
    New-Item -ItemType Directory "$noRepo/scripts" | Out-Null
    Copy-Item "$root/scripts/*" "$noRepo/scripts/"
    Push-Location $noRepo
    try {
        $env:GIT_CEILING_DIRECTORIES = $noRepo
        $r = Invoke-Gate 'routine ingest'
        Report 'git failing under the gate -> exit 2 with the git error' (($r.Code -eq 2) -and ($r.Out -match 'VAULT GATE ERROR: git diff .* failed with exit \d+: (error|fatal):')) "exit $($r.Code)`n$($r.Out)"
    } finally { Pop-Location; Remove-Item Env:GIT_CEILING_DIRECTORIES; Remove-Item -LiteralPath $noRepo -Recurse -Force }

    # The installed hook, end to end: a real git commit has to be stopped by the gate and a clean
    # one has to go through. git runs commit-msg hooks through its own sh, so this covers the
    # shell wrapper as well as the validator.
    New-TestVault
    Push-Location $work
    try {
        $ErrorActionPreference = 'Continue'
        Copy-Item "$root/hooks/commit-msg" .git/hooks/commit-msg
        Add-Content raw/note-2026-01-05-first-planting.md 'Edit through the hook.'
        G add -A
        $out = git commit -q -m 'routine ingest' 2>&1 | Out-String
        Report 'installed hook blocks a real commit' (($LASTEXITCODE -ne 0) -and ($out -match 'VAULT GATE FAILED')) "exit $LASTEXITCODE`n$out"
        G reset -q --hard
        Set-Content raw/note-2026-01-08-frost.md 'First frost.'
        G add -A
        $out = git commit -q -m 'routine ingest' 2>&1 | Out-String
        Report 'installed hook lets a clean commit through' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE`n$out"
        $ErrorActionPreference = 'Stop'
    } finally { Pop-Location }

    # The digest: first run creates the tag; a later run lists the commits, calls out the
    # destructive one, shows every changelog addition including a merge resolution; marking
    # needs the exact printed hash; the next run is empty; a tag off the branch is refused.
    New-TestVault
    Push-Location $work
    try {
        $first = Invoke-Digest
        Report 'digest creates the reviewed tag on first run' (($LASTEXITCODE -eq 0) -and ($first -match "Created the 'reviewed' tag")) $first
        Set-Content areas/gardening/entities/compost-bin.md $goodPage
        Add-Content meta/changelog.md $entry
        Add-Content meta/changelog.md ''
        Add-Content meta/changelog.md '+ 2026-01-10: a line that starts with a plus'
        G add -A
        G commit -qm 'add compost bin'
        Add-Content raw/note-2026-01-05-first-planting.md 'Correction.'
        G add -A
        G commit -qm '  [destructive] fix planting count'
        # A merge whose only changelog change is in the resolution itself.
        G switch -qc side
        Add-Content meta/changelog.md '- 2026-01-11: side branch entry'
        G add -A
        G commit -qm 'side entry'
        G switch -q -
        Add-Content meta/changelog.md '- 2026-01-11: main branch entry'
        G add -A
        G commit -qm 'main entry'
        $ErrorActionPreference = 'Continue'
        git merge side --no-edit -q 2>&1 | Out-Null
        $ErrorActionPreference = 'Stop'
        [System.IO.File]::WriteAllText("$work/meta/changelog.md", ((@(Get-Content meta/changelog.md | Where-Object { $_ -notmatch '^[<=>]{7}' }) + '- 2026-01-11: resolution-only entry') -join "`n") + "`n")
        G add -A
        G commit -qm 'merge side'
        $digest = Invoke-Digest
        $head = (git rev-parse HEAD).Trim()
        Report 'digest lists the commits and the hash to mark' (($digest -match '5 commit\(s\)') -and ($digest -match [regex]::Escape("-Through $head"))) $digest
        Report 'digest calls out the destructive commit, subject trimmed like the gate' ($digest -match '(?m)^[0-9a-f]+  \s*\[destructive\] fix planting count') $digest
        Report 'digest shows every changelog addition: entry, blank, plus-prefixed, both branches, resolution' (
            ($digest -match 'Added \[\[Compost Bin\]\]') -and ($digest -match '(?m)^\+ 2026-01-10: a line that starts with a plus') -and
            ($digest -match 'side branch entry') -and ($digest -match 'main branch entry') -and ($digest -match 'resolution-only entry') -and
            ($digest -notmatch '\+\+\+ ')) $digest
        $noHash = Invoke-Digest -Mark
        Report 'marking without the hash is refused' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE`n$noHash"
        $headRef = Invoke-Digest -Mark -Through HEAD
        Report 'marking with HEAD instead of the printed hash is refused' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE`n$headRef"
        $short = Invoke-Digest -Mark -Through $head.Substring(0, 7)
        Report 'marking with a short hash is refused' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE`n$short"
        Invoke-Digest -Mark -Through $head | Out-Null
        $after = Invoke-Digest
        Report 'after marking, the digest is empty' ($after -match 'Nothing new') $after
        G switch -q --orphan orphan
        New-Item -ItemType Directory scripts -Force | Out-Null
        Copy-Item "$root/scripts/*" scripts/
        Set-Content orphan.md 'unrelated history'
        G add -A
        G commit -qm 'orphan root'
        $refused = Invoke-Digest
        Report 'digest refuses when the reviewed tag is not an ancestor of HEAD' (($LASTEXITCODE -ne 0) -and ($refused -match 'not an ancestor')) "exit $LASTEXITCODE`n$refused"
        $ErrorActionPreference = 'Stop'
    } finally { Pop-Location }
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
}

if ($script:failed) { Write-Host "`n$script:failed scenario(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll scenarios passed." -ForegroundColor Green
exit 0
