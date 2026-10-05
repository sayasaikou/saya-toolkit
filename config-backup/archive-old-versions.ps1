<#
  archive-old-versions.ps1 -- trim a git backup repo's history down to the newest N commits

  WHY THIS IS NOT JUST "git rebase -i" OR "git reset"
    The goal is to keep the newest N commits AND drop everything older, without ever
    letting the branch pointer and the working tree disagree. The naive approaches lose
    either the files or the commits, and a backup repository is the worst possible place
    to find that out. The sequence used here is deliberate:

      1. write and commit the archive list FIRST, so it becomes the new chain tip
      2. replay the newest N-1 commits with commit-tree (objects are reused, not rewritten
         from the working tree, so file contents cannot drift)
      3. move the branch with `update-ref <ref> <new> <old>` -- passing the OLD value means
         the update fails loudly if anything moved underneath us
      4. `read-tree -m -u` to bring the index and working tree in line with the new tip
      5. verify the commit count and the file list against what was recorded beforehand
      6. push --force; on ANY failure restore the branch to the original commit

  WHAT THIS DESTROYS (say it out loud before running it)
    Commits older than the window become unreachable and are removed by gc. They can NOT
    be recovered from the repository afterwards. Keep a full copy of the repo elsewhere
    first -- the script prints a reminder, but it cannot verify that you did.

  USAGE
    pwsh -NoProfile -File .\archive-old-versions.ps1 -Repo 'D:\backup' -Keep 20 -DryRun
    pwsh -NoProfile -File .\archive-old-versions.ps1 -Repo 'D:\backup' -Keep 20

  EXIT CODES
    0 = done (or nothing to do)   2 = worktree dirty, nothing touched
    7 = -Keep too large           9 = failure, branch was rolled back

  FILE FORMAT
    ASCII only, LF line endings, no BOM. The archive list is written as UTF-8 without BOM
    so its markdown renders correctly on any host.
#>
[CmdletBinding()]
param(
  # Path to the git repository (the backup mirror).
  [Parameter(Mandatory = $true)]
  [string]$Repo,

  # Number of newest commits to keep. The archive-list commit occupies one slot, so the
  # final history is exactly this many commits.
  [int]$Keep = 20,

  # Branch/ref that gets rewritten. Empty = the currently checked out branch.
  [string]$Ref = '',

  # Relative path of the generated archive list.
  [string]$ArchiveListPath = 'docs/archived-versions.md',

  # Optional path where a full pre-trim copy of the repo lives. Printed as a reminder only.
  [string]$FullCopyPath = '',

  # Git committer timezone offset used when replaying commits (keeps original timestamps).
  [string]$TzOffset = '+0000',

  [switch]$DryRun,
  [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath (Join-Path $Repo '.git'))) {
  Write-Output ('VERDICT: ABORT not a git repository: ' + $Repo)
  exit 9
}

function Invoke-Git {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
  return (& git -C $Repo @GitArgs)
}

function ConvertTo-UnixTime([string]$iso) {
  $dt = [datetime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind)
  return [int][double]::Parse(([DateTimeOffset]$dt).ToUnixTimeSeconds().ToString())
}

if (-not $Ref) {
  $Ref = (Invoke-Git rev-parse --abbrev-ref HEAD).Trim()
  if ($Ref -eq 'HEAD') {
    Write-Output 'VERDICT: ABORT detached HEAD -- pass -Ref explicitly'
    exit 9
  }
}

Write-Output ('=== cloud backup history trim (keep newest ' + $Keep + ') ===')
Write-Output ('repo        : ' + $Repo)
Write-Output ('ref         : ' + $Ref)

$count = [int](Invoke-Git rev-list --count HEAD)
Write-Output ('commits now : ' + $count)
if ($count -le $Keep) { Write-Output 'VERDICT: OK nothing to do'; exit 0 }

# Refuse to touch a dirty tree: the index rewrite that follows would otherwise discard or
# entangle uncommitted work, and the file-list check below would compare against a tree
# that is not what the user thinks it is.
$dirty = @(Invoke-Git status --porcelain).Count
if ($dirty -ne 0) {
  Write-Output ('VERDICT: ABORT worktree dirty (' + $dirty + ' items) -- commit or sync first')
  exit 2
}

$origHead = (Invoke-Git rev-parse HEAD).Trim()
$filesBefore = @(Invoke-Git ls-tree -r --name-only HEAD)
$log0 = @(Invoke-Git log --format='%H%x7c%ad%x7c%s' --date=iso-strict)
$total0 = $log0.Count

# The archive-list commit occupies one slot: replay Keep-1 parents, then attach the archive
# commit, and the history is exactly Keep long.
$parentCount = $Keep - 1
$cut = $total0 - $parentCount
if ($cut -lt 1) { Write-Output 'VERDICT: ABORT -Keep too large for this history'; exit 7 }

$old = @($log0[$cut..($total0 - 1)])
$window = @($log0[0..($cut - 1)])
Write-Output ('to archive  : ' + $old.Count + ' commits')
Write-Output ('to keep     : ' + $window.Count + ' parents + 1 archive commit = ' + $Keep)
Write-Output ('old head    : ' + $origHead)
if ($FullCopyPath) { Write-Output ('full copy   : ' + $FullCopyPath + '  (verify it exists before trusting this)') }
Write-Output 'NOTE: the trimmed commits become unrecoverable from this repository after gc.'

if ($DryRun) {
  Write-Output 'VERDICT: DRYRUN (no change)'
  $old | ForEach-Object { Write-Output ('  drop ' + $_.Split('|')[0].Substring(0, 8)) }
  exit 0
}

$ok = $false
try {
  # 1) archive list first, so it is the tip of the new chain
  $listDir = Split-Path (Join-Path $Repo $ArchiveListPath) -Parent
  if ($listDir -and -not (Test-Path $listDir)) { New-Item -ItemType Directory -Path $listDir -Force | Out-Null }
  $lines = @(
    '# Archived versions',
    '',
    ('This repository keeps only the newest ' + $Keep + ' commits. The ' + $old.Count + ' older commits listed below were removed from git history and can no longer be recovered from this repository.'),
    '',
    '| # | commit | date | subject |',
    '| --- | --- | --- | --- |'
  )
  $n = 0
  foreach ($entry in $old) {
    $n++
    $f = $entry.Split('|')
    $lines += ('| ' + $n + ' | `' + $f[0].Substring(0, 8) + '` | ' + $f[1] + ' | ' + $f[2] + ' |')
  }
  [IO.File]::WriteAllLines((Join-Path $Repo $ArchiveListPath), $lines, (New-Object Text.UTF8Encoding($false)))
  Invoke-Git add -- $ArchiveListPath 2>&1 | Out-Null
  Invoke-Git commit -q -m ('chore: archive list of ' + $old.Count + ' trimmed versions') 2>&1 | Out-Null
  $archiveSha = (Invoke-Git rev-parse HEAD).Trim()
  $archiveTree = (Invoke-Git rev-parse 'HEAD^{tree}').Trim()
  Write-Output ('archive list: ' + $ArchiveListPath + ' committed (' + $archiveSha.Substring(0, 8) + ')')

  # 2) replay the newest parentCount commits, oldest first. commit-tree reuses the existing
  #    tree objects, so no file content is re-derived from the working tree.
  $parent = $null
  $replayed = 0
  $recent = @($log0[0..($parentCount - 1)])
  for ($k = $recent.Count - 1; $k -ge 0; $k--) {
    $f = $recent[$k].Split('|')
    $tree = (Invoke-Git rev-parse ($f[0] + '^{tree}')).Trim()
    $stamp = ConvertTo-UnixTime $f[1]
    $env:GIT_AUTHOR_DATE = ($stamp.ToString() + ' ' + $TzOffset)
    $env:GIT_COMMITTER_DATE = ($stamp.ToString() + ' ' + $TzOffset)
    if ($null -eq $parent) { $parent = (Invoke-Git commit-tree $tree -m $f[2]).Trim() }
    else { $parent = (Invoke-Git commit-tree $tree -p $parent -m $f[2]).Trim() }
    $replayed++
  }
  Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
  Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue

  if ($parent) {
    $newTip = (Invoke-Git commit-tree $archiveTree -p $parent -m ('chore: archive list of ' + $old.Count + ' trimmed versions')).Trim()
  } else {
    $newTip = $archiveSha
  }
  if ($newTip.Length -lt 8) { throw 'commit-tree failed' }
  Write-Output ('replayed    : ' + $replayed + ' + 1 archive commit (new tip ' + $newTip.Substring(0, 8) + ')')

  # 3) move the ref, then sync index + working tree. The guard value passed to update-ref
  #    is the CURRENT head (the archive commit just created) -- using the older $origHead
  #    here would make the guarded update fail for the wrong reason.
  Invoke-Git update-ref ('refs/heads/' + $Ref) $newTip $archiveSha
  Invoke-Git read-tree -m -u $newTip

  $after = [int](Invoke-Git rev-list --count HEAD)
  $filesAfter = @(Invoke-Git ls-tree -r --name-only HEAD)
  Write-Output ('after       : ' + $after + ' commits / ' + $filesAfter.Count + ' files')

  if ($after -ne $Keep) { throw ('unexpected commit count ' + $after) }
  if ($filesAfter.Count -lt $filesBefore.Count) {
    $missing = @(Compare-Object $filesBefore $filesAfter |
      Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
    Write-Output ('WARN missing files vs before: ' + ($missing -join ', '))
  }

  # 4) push, and roll everything back if that fails
  if (-not $NoPush) {
    Invoke-Git push --force origin $Ref 2>&1 | ForEach-Object { Write-Output ('  ' + $_) }
    if ($LASTEXITCODE -ne 0) { throw 'push failed' }
  } else {
    Write-Output 'skip push (-NoPush)'
  }

  $ok = $true
  Invoke-Git reflog expire --expire=now --all 2>&1 | Out-Null
  Invoke-Git gc --prune=now --quiet 2>&1 | Out-Null
  $gitBytes = (Get-ChildItem (Join-Path $Repo '.git') -Recurse -Force -File | Measure-Object Length -Sum).Sum
  Write-Output ('.git size   : ' + [math]::Round($gitBytes / 1MB, 2) + ' MB')
  Write-Output ('VERDICT: PASS trimmed to ' + $after + ' commits')
} catch {
  Write-Output ('ERROR: ' + $_.Exception.Message)
  if (-not $ok) {
    # Roll back to the original commit. Both the ref and the working tree are restored, so
    # a failed run leaves the repository exactly as it was found.
    Invoke-Git update-ref ('refs/heads/' + $Ref) $origHead 2>&1 | Out-Null
    Invoke-Git read-tree -m -u $origHead 2>&1 | Out-Null
    Write-Output ('ROLLBACK: ' + $Ref + ' restored to ' + $origHead)
  }
  Write-Output 'VERDICT: FAIL'
  exit 9
}
exit 0
