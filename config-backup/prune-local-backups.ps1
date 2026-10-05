<#
  prune-local-backups.ps1 -- delete *.bak-* snapshots that are older than N days

  WHY THE AGE TEST USES "BORN TIME", NOT LastWriteTime (this is the whole trick)
    Copy-Item preserves the source file's LastWriteTime. A rollback point created TODAY
    from a config file that was written three days ago therefore carries a three-day-old
    LastWriteTime, and a naive age test deletes the freshest backup first -- exactly
    backwards. The age test here uses the LATER of CreationTime and LastWriteTime.

  WHITELIST
    Some snapshots are irreplaceable (they are the only copy of a known-good state), so
    they must survive the age rule forever, or until a human says otherwise. -KeepPattern
    adds such patterns; every skip is printed together with its reason, so the report
    never silently keeps something.

  USAGE
    pwsh -NoProfile -File .\prune-local-backups.ps1 -DryRun
    pwsh -NoProfile -File .\prune-local-backups.ps1 -KeepDays 3
    pwsh -NoProfile -File .\prune-local-backups.ps1 -Root 'D:\backup' -KeepPattern 'release-*'

  EXIT CODES
    0 = nothing to prune, or pruned cleanly    3 = some files could not be deleted

  DEFAULT IS A DRY RUN? No -- but -DryRun is strongly recommended for the first run.
  Deletion is permanent; nothing is moved to the recycle bin.

  FILE FORMAT
    ASCII only, LF line endings, no BOM (PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI,
    so a scheduled script must stay pure ASCII).
#>
[CmdletBinding()]
param(
  # Folder scanned recursively for *.bak-* files.
  [string]$Root = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Snapshots younger than this many days are kept.
  [int]$KeepDays = 3,

  # Extra whitelist patterns (wildcards). Matching files are never deleted.
  [string[]]$KeepPattern = @(),

  # Folders excluded from the scan entirely.
  [string[]]$ExcludeDir = @(),

  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Root)) {
  Write-Output ('VERDICT: OK root not found, nothing to do: ' + $Root)
  exit 0
}

$cutoff = (Get-Date).AddDays(-$KeepDays)

# TECH NOTE: CreationTime can be later than LastWriteTime after a copy, and either one can
# be the "when did this rollback point appear" answer. Take the later of the two.
function Get-BornTime($f) {
  if ($f.CreationTime -gt $f.LastWriteTime) { return $f.CreationTime }
  return $f.LastWriteTime
}

Write-Output ('=== prune-local-backups (keep ' + $KeepDays + ' days) ===')
Write-Output ('root       : ' + $Root)
Write-Output ('cutoff     : ' + $cutoff.ToString('yyyy-MM-dd HH:mm'))

# Built-in whitelist: patterns that are almost always irreplaceable. Override with
# -KeepPattern, and keep the reasons visible in the report.
$keepRules = @(
  @{ Pat = '*release*';   Why = 'release rollback point' },
  @{ Pat = '*known-good*'; Why = 'known-good state' }
)
foreach ($p in $KeepPattern) { $keepRules += @{ Pat = $p; Why = 'user whitelist (-KeepPattern)' } }

function Test-Whitelisted([string]$full) {
  foreach ($r in $keepRules) { if ($full -like $r.Pat) { return $r.Why } }
  return $null
}

function Test-Excluded([string]$full) {
  foreach ($d in $ExcludeDir) {
    if ($d -and ($full -like ('*' + $d + '*') -or $full -like ('*' + $d.TrimEnd('\') + '\*'))) { return $true }
  }
  return $false
}

$all = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*.bak-*' -and -not (Test-Excluded $_.FullName) })

$expired = @($all | Where-Object { (Get-BornTime $_) -lt $cutoff })
Write-Output ('bak files  : ' + $all.Count + ' total / ' + $expired.Count + ' older than cutoff')

$kept = @(); $del = @(); $protected = @()
foreach ($f in $expired) {
  $why = Test-Whitelisted $f.FullName
  if ($why) { $protected += ($f.Name + '  <- ' + $why); continue }
  $del += $f
}
$kept = @($all | Where-Object { (Get-BornTime $_) -ge $cutoff })
Write-Output ('keep (in window): ' + $kept.Count)
if ($protected.Count) {
  Write-Output ('keep (whitelisted): ' + $protected.Count)
  $protected | ForEach-Object { Write-Output ('  ' + $_) }
}

if (-not $del.Count) { Write-Output 'VERDICT: OK nothing to prune'; exit 0 }

if ($DryRun) {
  Write-Output 'VERDICT: DRYRUN (no change)'
  foreach ($f in $del) {
    Write-Output ('  would del ' + (Get-BornTime $f).ToString('MM-dd HH:mm') + '  ' + $f.FullName)
  }
  exit 0
}

$freed = 0; $done = 0; $failed = @()
foreach ($f in $del) {
  try {
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
    $freed += $f.Length
    $done++
  } catch {
    $failed += ($f.Name + ': ' + $_.Exception.Message)
  }
}

Write-Output ('pruned     : ' + $done + ' files / ' + [math]::Round($freed / 1KB, 1) + ' KB')
if ($failed.Count) {
  Write-Output ('FAILED     : ' + $failed.Count)
  $failed | ForEach-Object { Write-Output ('  ' + $_) }
}
$left = @(Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -like '*.bak-*' })
Write-Output ('bak left   : ' + $left.Count)
if ($failed.Count) { Write-Output 'VERDICT: PARTIAL'; exit 3 }
Write-Output 'VERDICT: PASS'
exit 0
