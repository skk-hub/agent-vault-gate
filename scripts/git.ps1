# Shared by validate-vault.ps1 and review-digest.ps1: every git call goes through here so a failing
# git command throws (with git's own stderr in the message) instead of returning empty output that
# the caller would read as "nothing to check". Exit codes in -Ok are not failures (git grep exits
# 1 on no match). $LASTEXITCODE is left set for callers that need to tell the -Ok codes apart.
function Invoke-Git([string[]]$GitArgs, [int[]]$Ok = @(0)) {
  $ErrorActionPreference = 'Continue'
  $stderr = [System.Collections.Generic.List[string]]::new()
  $output = & git -c core.quotepath=false @GitArgs 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $stderr.Add([string]$_) } else { $_ }
  }
  if ($LASTEXITCODE -notin $Ok) { throw "git $($GitArgs -join ' ') failed with exit ${LASTEXITCODE}: $($stderr -join ' ')" }
  return $output
}
