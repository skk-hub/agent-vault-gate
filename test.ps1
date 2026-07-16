# test.ps1 - proves the gate catches each violation class it claims to.
# Builds a throwaway git repo from sample-vault/, stages a change per scenario,
# and asserts the validator's exit code. No frameworks, no dependencies.
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$ps = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $ps) { $ps = Get-Command powershell }
$work = Join-Path ([System.IO.Path]::GetTempPath()) "vault-gate-test-$(Get-Random)"

function New-TestVault {
    if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    New-Item -ItemType Directory $work | Out-Null
    Copy-Item "$root/sample-vault/*" $work -Recurse
    New-Item -ItemType Directory "$work/scripts" | Out-Null
    Copy-Item "$root/scripts/validate-vault.ps1" "$work/scripts/"
    Push-Location $work
    git init -q
    git config core.autocrlf false
    git add -A
    git -c user.email=test@test -c user.name=test commit -qm seed | Out-Null
    Pop-Location
}

$script:failed = 0
function Assert-Gate([string]$name, [int]$expected, [scriptblock]$change, [string]$subject = 'routine ingest') {
    New-TestVault
    Push-Location $work
    & $change
    git add -A
    Set-Content "$work/.msg" $subject
    & $ps.Source -NoProfile -File scripts/validate-vault.ps1 "$work/.msg" > "$work/.gate-out" 2>&1
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -eq $expected) {
        Write-Host "PASS  $name" -ForegroundColor Green
    } else {
        $script:failed++
        Write-Host "FAIL  $name (expected exit $expected, got $code)" -ForegroundColor Red
        Get-Content "$work/.gate-out" | ForEach-Object { Write-Host "      $_" }
    }
}

$goodPage = @'
---
title: Compost Bin
type: entity
area: gardening
created: 2026-01-10
updated: 2026-01-10
review_by: 2026-04-10
sources: [raw/note-2026-01-05-first-planting.md]
status: active
---

# Compost Bin

Behind the shed. Feeds the [[Tomato Bed]].
'@

Assert-Gate 'valid new page + changelog entry -> accepted' 0 {
    Set-Content areas/gardening/entities/compost-bin.md $goodPage
    Add-Content meta/changelog.md '- 2026-01-10: Added [[Compost Bin]].'
}

Assert-Gate 'frontmatter missing review_by -> blocked' 1 {
    Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace 'review_by: .+\r?\n', '')
    Add-Content meta/changelog.md '- 2026-01-10: Added [[Compost Bin]].'
}

Assert-Gate 'area field contradicts directory -> blocked' 1 {
    Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace 'area: gardening', 'area: cooking')
    Add-Content meta/changelog.md '- 2026-01-10: Added [[Compost Bin]].'
}

Assert-Gate 'editing an evidence snapshot in raw/ -> blocked' 1 {
    Add-Content raw/note-2026-01-05-first-planting.md 'Actually it was five plants.'
}

Assert-Gate 'same raw/ edit with [destructive] marker -> accepted (loud path)' 0 {
    Add-Content raw/note-2026-01-05-first-planting.md 'Correction with human sign-off.'
} -subject '[destructive] fix planting count in snapshot'

Assert-Gate 'deleting a page without [destructive] -> blocked' 1 {
    git rm -q areas/gardening/notes/watering-schedule.md
}

Assert-Gate 'wiki edit without a changelog entry -> blocked' 1 {
    Add-Content areas/gardening/entities/tomato-bed.md 'Mulched 2026-01-12.'
}

Assert-Gate 'broken wikilink -> blocked' 1 {
    Set-Content areas/gardening/entities/compost-bin.md ($goodPage -replace '\[\[Tomato Bed\]\]', '[[No Such Page]]')
    Add-Content meta/changelog.md '- 2026-01-10: Added [[Compost Bin]].'
}

try { Remove-Item $work -Recurse -Force -ErrorAction Stop } catch {}
if ($script:failed) { Write-Host "`n$script:failed scenario(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "`nAll scenarios passed." -ForegroundColor Green
exit 0
