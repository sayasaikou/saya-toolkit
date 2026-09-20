<#
  restore.ps1 -- lay config / scripts / notes from a backup repo back onto this machine

  DEFAULT IS A DRY RUN: it only lists what would be overwritten and writes nothing.
  Add -Apply to really write. Before a file is overwritten, the existing copy is saved
  next to itself as *.bak-<timestamp> -- the original is never deleted.

  USAGE
    pwsh -NoProfile -File .\restore.ps1                                # dry run (safe)
    pwsh -NoProfile -File .\restore.ps1 -Apply                         # really write
    pwsh -NoProfile -File .\restore.ps1 -TargetRoot C:\temp\dsh-drill -Apply  # rehearse into a fake dir
    pwsh -NoProfile -File .\restore.ps1 -NoPull                        # skip git pull, use local clone

  THREE SAFETY NETS
    1. dry run by default -- nothing is written unless -Apply is passed
    2. every existing file is copied to *.bak-<timestamp> before it is replaced
    3. -TargetRoot can point anywhere, so a rollback can be rehearsed on a throwaway tree

  PREREQUISITES / LAYOUT
    The repository must mirror the DSH home 1:1: the tree inside the repo equals the tree
    under -TargetRoot. The single exception is workspace-AGENTS.md, which is mapped back
    to -WorkspaceAgents (or to <TargetRoot>\workspace-AGENTS.md when that is not given).
    The files of the repo itself (sync/restore/health-check/README/.gitignore) are never
    written back onto the target.

  FILE FORMAT
    ASCII only, LF line endings, no BOM. Windows PowerShell 5.1 parses a BOM-less UTF-8
    file as ANSI, so a script that gets scheduled must stay ASCII.
#>
[CmdletBinding()]
param(
  # Without this switch the script only prints the plan.
  [switch]$Apply,

  # Destination root (the DSH home by default).
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$TargetRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Where workspace-AGENTS.md from the repo should land. Empty = under -TargetRoot.
  # A sensible value is (Join-Path $env:DSH_WORKSPACE 'AGENTS.md').
  [string]$WorkspaceAgents = '',

  # Backup repo (the folder holding this script). Empty = the script's own folder.
  [string]$RepoDir = '',

  [switch]$NoPull
)

$ErrorActionPreference = 'Continue'

if (-not $RepoDir) { $RepoDir = $PSScriptRoot }
$Repo  = $RepoDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$WsFile = $WorkspaceAgents
if (-not $WsFile) { $WsFile = Join-Path $TargetRoot 'workspace-AGENTS.md' }

Write-Host '=== restore.ps1 ===' -ForegroundColor Cyan
Write-Host ('repo   : ' + $Repo)
Write-Host ('target : ' + $TargetRoot)
if ($Apply) { Write-Host 'mode   : APPLY -- files WILL be written' -ForegroundColor Red }
else        { Write-Host 'mode   : DRY RUN -- list only, nothing is written' -ForegroundColor Yellow }

# 1) pull first, unless told not to (a rollback from a stale clone is a silent failure)
if (-not $NoPull) {
  Push-Location $Repo
  & git pull --ff-only 2>&1 | Select-Object -Last 3 | ForEach-Object { '  ' + $_ }
  Pop-Location
}

# 2) the repo's own files are never written back onto the target
$SelfFiles = @('README.md', 'sync.ps1', 'restore.ps1', 'health-check.ps1', '.gitignore')

$plan = @()
Get-ChildItem $Repo -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
  ForEach-Object {
    $rel = $_.FullName.Substring($Repo.Length + 1)
    $relSlash = $rel -replace '\\', '/'
    if ($SelfFiles -contains $relSlash) { return }
    if ($relSlash -eq 'workspace-AGENTS.md') {
      $plan += [pscustomobject]@{ Src = $_.FullName; Dst = $WsFile }
    } else {
      $plan += [pscustomobject]@{ Src = $_.FullName; Dst = (Join-Path $TargetRoot $rel) }
    }
  }

Write-Host ('plan   : ' + $plan.Count + ' files') -ForegroundColor Cyan

$written = 0
$backedUp = 0
foreach ($p in $plan) {
  if (-not $Apply) {
    Write-Host ('  [dry] ' + $p.Dst)
    continue
  }
  $dir = Split-Path $p.Dst -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path $p.Dst) {
    # TECH NOTE: one backup per run and per file ('if (-not (Test-Path $bak))'). A second
    # run in the same minute would otherwise overwrite the first, clean backup with the
    # already-broken file it just restored.
    $bak = $p.Dst + '.bak-' + $stamp
    if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $p.Dst -Destination $bak -Force; $backedUp++ }
  }
  Copy-Item -LiteralPath $p.Src -Destination $p.Dst -Force
  $written++
}

if ($Apply) {
  Write-Host ('restored : ' + $written + ' files') -ForegroundColor Green
  Write-Host ('backed up: ' + $backedUp + ' previous versions (*.bak-' + $stamp + ')') -ForegroundColor Green
} else {
  Write-Host 'DRY RUN finished -- re-run with -Apply once the plan looks right.' -ForegroundColor Yellow
}
