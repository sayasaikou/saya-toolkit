<#
  prune-snapshots.ps1 -- delete dated snapshot folders older than N days

  SCOPE RULE (do not loosen this)
    Only directories whose NAME matches yyyy-MM-dd are candidates. Everything else in the
    snapshot root -- README files, launcher .bat files, logs, a manual restore folder --
    is left strictly alone. A snapshot tool that deletes "whatever looks old" eventually
    deletes something it did not create.

  BOUNDARY
    The cutoff day is KEPT: with -KeepDays 7 on the 10th, the 3rd is kept and the 2nd is
    deleted. Stated explicitly because "7 days" is ambiguous at the boundary and someone
    will eventually read the report and ask.

  USAGE
    pwsh -NoProfile -File .\prune-snapshots.ps1 -Root 'D:\snapshots' -DryRun
    pwsh -NoProfile -File .\prune-snapshots.ps1 -Root 'D:\snapshots' -KeepDays 7

  EXIT CODES
    0 = nothing to prune, or pruned cleanly    3 = some folders could not be deleted

  FILE FORMAT
    ASCII only, LF line endings, no BOM. Reports sizes in MB for readability; the byte
    total is the sum over files, so sparse or compressed content may differ from what
    Explorer shows.
#>
[CmdletBinding()]
param(
  # Folder holding the dated snapshot directories. Required -- there is deliberately no
  # default, because a wrong default here deletes the wrong tree.
  [Parameter(Mandatory = $true)]
  [string]$Root,

  # Snapshot folders this many days old (and newer) are kept. The cutoff day itself is kept.
  [int]$KeepDays = 7,

  # Optional log file. Empty = print only.
  [string]$LogFile = '',

  [switch]$DryRun
)

$ErrorActionPreference = 'Continue'

function Write-Log([string]$text) {
  Write-Output $text
  if ($LogFile) {
    $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $text
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
  }
}

$today = (Get-Date).Date
$cutoff = $today.AddDays(-$KeepDays)

Write-Log ('=== prune-snapshots (keep ' + $KeepDays + ' days) ===')
Write-Log ('root       : ' + $Root)
Write-Log ('cutoff     : ' + $cutoff.ToString('yyyy-MM-dd') + '  (this day and newer are kept)')

if (-not (Test-Path -LiteralPath $Root)) {
  Write-Log ('VERDICT: OK snapshot root not found, nothing to do: ' + $Root)
  exit 0
}

$all = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })

$del = @(); $keep = @()
foreach ($d in $all) {
  # TECH NOTE: TryParseExact with an explicit yyyy-MM-dd format, because a folder named
  # 2026-13-45 passes the regex but is not a date, and comparing an unparsed name silently
  # makes the folder immortal (it never appears older than the cutoff).
  $dt = [datetime]::MinValue
  $parsed = [datetime]::TryParseExact($d.Name, 'yyyy-MM-dd', $null,
              [System.Globalization.DateTimeStyles]::None, [ref]$dt)
  if (-not $parsed) { Write-Log ('SKIP (unparseable date): ' + $d.Name); continue }
  if ($dt.Date -lt $cutoff) { $del += $d } else { $keep += $d }
}

$keepNames = @($keep | Sort-Object Name)
$span = 'none'
if ($keepNames.Count -gt 0) { $span = $keepNames[0].Name + ' .. ' + $keepNames[$keepNames.Count - 1].Name }
Write-Log ('snapshots  : ' + $all.Count + ' total / ' + $del.Count + ' older than cutoff')
Write-Log ('keep       : ' + $keep.Count + '  (' + $span + ')')

if (-not $del.Count) { Write-Log 'VERDICT: OK nothing to prune'; exit 0 }

$totalBytes = 0
foreach ($d in $del) {
  $totalBytes += (Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
}

if ($DryRun) {
  Write-Log 'VERDICT: DRYRUN (no change)'
  foreach ($d in $del) { Write-Log ('  would del  ' + $d.Name) }
  Write-Log ('  would free : ' + ('{0:N1} MB' -f ($totalBytes / 1MB)))
  exit 0
}

$done = 0; $failed = @(); $freed = 0
foreach ($d in $del) {
  $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue |
         Measure-Object Length -Sum).Sum
  try {
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
    $done++
    $freed += $sz
  } catch {
    $failed += ($d.Name + ': ' + $_.Exception.Message)
  }
}

Write-Log ('pruned     : ' + $done + ' snapshots / ' + ('{0:N1} MB' -f ($freed / 1MB)))
if ($failed.Count) {
  Write-Log ('FAILED     : ' + $failed.Count)
  $failed | ForEach-Object { Write-Log ('  ' + $_) }
}
$left = @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })
Write-Log ('snapshots left : ' + $left.Count)
if ($failed.Count) { Write-Log 'VERDICT: PARTIAL'; exit 3 }
Write-Log 'VERDICT: PASS'
exit 0
