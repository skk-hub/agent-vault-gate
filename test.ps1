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
$script:failed = 0

function New-TestVault {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory $work | Out-Null
    Copy-Item "$root/sample-vault/*" $work -Recurse
    New-Item -ItemType Directory "$work/scripts" | Out-Null
    Copy-Item "$root/scripts/validate-vault.ps1" "$work/scripts/"
    Copy-Item "$root/scripts/review-digest.ps1" "$work/scripts/"
    # A non-ASCII filename in the seed, because git quotes those paths unless told not to.
    [System.IO.File]::WriteAllText("$work/raw/note-2026-01-07-café-visit.md", "Bought seeds at the café.`n")
    Push-Location $work
    try {
        git init -q
        git config core.autocrlf false
        git config user.email test@test
        git config user.name test
        git add -A
        git commit -qm seed | Out-Null
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

# Stages the change (unless the scenario stages by hand), runs the validator, and checks both the
# exit code and, when given, that the diagnostic names the rule that fired.
function Assert-Gate([string]$name, [int]$expected, [scriptblock]$change, [string]$subject = 'routine ingest', [string]$reason = '', [switch]$ManualStage) {
    New-TestVault
    Push-Location $work
    try {
        & $change
        if (-not $ManualStage) { git add -A }
        $r = Invoke-Gate $subject
    } finally { Pop-Location }
    $ok = ($r.Code -eq $expected) -and ($reason -eq '' -or $r.Out -match $reason)
    Report $name $ok "expected exit $expected$(if ($reason) { " matching '$reason'" }), got $($r.Code):`n$($r.Out)"
}

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
    Assert-Gate 'editing an evidence snapshot in raw/ -> blocked' 1 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Actually it was five plants.'
    } -reason 'append-only'
    Assert-Gate 'editing a raw/ file with a non-ASCII name -> blocked' 1 {
        Add-Content -LiteralPath 'raw/note-2026-01-07-café-visit.md' 'And a trowel.'
    } -reason 'append-only'
    Assert-Gate 'same raw/ edit with [destructive] marker -> accepted (loud path)' 0 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Correction with human sign-off.'
    } -subject '[destructive] fix planting count in snapshot'
    Assert-Gate 'marker mentioned mid-subject is not an override -> blocked' 1 {
        Add-Content raw/note-2026-01-05-first-planting.md 'Sneaky edit.'
    } -subject 'document what [destructive] means' -reason 'append-only'
    Assert-Gate 'deleting a page without [destructive] -> blocked' 1 {
        git rm -q areas/gardening/notes/watering-schedule.md
    } -reason 'requires a \[destructive\]'
    Assert-Gate 'turning a page into a symlink -> blocked' 1 {
        $blob = ('elsewhere.md' | git hash-object -w --stdin).Trim()
        git update-index --cacheinfo "120000,$blob,areas/gardening/entities/tomato-bed.md"
    } -reason 'type changes' -ManualStage
    Assert-Gate 'wiki edit without a changelog entry -> blocked' 1 {
        Add-Content areas/gardening/entities/tomato-bed.md 'Mulched 2026-01-12.'
    } -reason 'without an added or modified'
    Assert-Gate 'deleting the changelog does not count as a changelog entry -> blocked' 1 {
        Add-Content areas/gardening/entities/tomato-bed.md 'Mulched 2026-01-12.'
        git rm -q meta/changelog.md
    } -subject '[destructive] drop the changelog' -reason 'without an added or modified'
    Assert-Gate 'broken wikilink -> blocked' 1 {
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[No Such Page]]')
        Add-Content meta/changelog.md $entry
    } -reason 'broken wikilink'
    Assert-Gate 'wikilink satisfied only by an unstaged file -> blocked' 1 {
        Set-Content areas/gardening/entities/garden-shed.md $shedPage
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[Garden Shed]]')
        Add-Content meta/changelog.md $entry
        git add areas/gardening/entities/compost-bin.md meta/changelog.md
    } -reason 'broken wikilink' -ManualStage
    Assert-Gate 'wikilink to a quoted frontmatter title in the same commit -> accepted' 0 {
        Set-Content areas/gardening/entities/garden-shed.md $shedPage
        Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[Garden Shed]]')
        Add-Content meta/changelog.md $entry
    }

    # The installed hook, end to end: a real git commit has to be stopped by the gate and a clean
    # one has to go through. git runs commit-msg hooks through its own sh, so this covers the
    # shell wrapper as well as the validator.
    New-TestVault
    Push-Location $work
    try {
        $ErrorActionPreference = 'Continue'
        Copy-Item "$root/hooks/commit-msg" .git/hooks/commit-msg
        Add-Content raw/note-2026-01-05-first-planting.md 'Edit through the hook.'
        git add -A
        $out = git commit -q -m 'routine ingest' 2>&1 | Out-String
        Report 'installed hook blocks a real commit' (($LASTEXITCODE -ne 0) -and ($out -match 'VAULT GATE FAILED')) "exit $LASTEXITCODE`n$out"
        git reset -q --hard
        Set-Content raw/note-2026-01-08-frost.md 'First frost.'
        git add -A
        $out = git commit -q -m 'routine ingest' 2>&1 | Out-String
        Report 'installed hook lets a clean commit through' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE`n$out"
        $ErrorActionPreference = 'Stop'
    } finally { Pop-Location }

    # The digest: first run creates the tag, a later run lists the commit and its changelog line,
    # marking needs the printed hash, and the next run is empty.
    New-TestVault
    Push-Location $work
    try {
        $ErrorActionPreference = 'Continue'
        $first = & $ps -NoProfile -File scripts/review-digest.ps1 2>&1 | Out-String
        Report 'digest creates the reviewed tag on first run' (($LASTEXITCODE -eq 0) -and ($first -match "Created the 'reviewed' tag")) $first
        Set-Content areas/gardening/entities/compost-bin.md $goodPage
        Add-Content meta/changelog.md $entry
        git add -A
        git commit -qm 'add compost bin' | Out-Null
        $digest = & $ps -NoProfile -File scripts/review-digest.ps1 2>&1 | Out-String
        $head = (git rev-parse HEAD).Trim()
        Report 'digest lists the commit, its changelog line and the hash to mark' (($digest -match '1 commit\(s\)') -and ($digest -match 'Added \[\[Compost Bin\]\]') -and ($digest -match [regex]::Escape("-Through $head"))) $digest
        $noHash = & $ps -NoProfile -File scripts/review-digest.ps1 -Mark 2>&1 | Out-String
        Report 'marking without the hash is refused' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE`n$noHash"
        & $ps -NoProfile -File scripts/review-digest.ps1 -Mark -Through $head 2>&1 | Out-Null
        $after = & $ps -NoProfile -File scripts/review-digest.ps1 2>&1 | Out-String
        Report 'after marking, the digest is empty' ($after -match 'Nothing new') $after
        $ErrorActionPreference = 'Stop'
    } finally { Pop-Location }
}
finally {
    if ((Get-Location).Path -eq $work) { Pop-Location }
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop }
}

if ($script:failed) { Write-Host "`n$script:failed scenario(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll scenarios passed." -ForegroundColor Green
exit 0
