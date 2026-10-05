<#
  maintenance-daily.ps1 -- run the retention jobs and write one log

  WHY A WRAPPER INSTEAD OF THREE SCHEDULED TASKS
    Three separate tasks means three places to notice that one of them silently stopped
    running, and a task that fails every night looks exactly like a task that has nothing
    to do. Here each job's VERDICT line is extracted into a single log, so one glance at
    the log answers "did last night actually work".

  WHY THE LOG IS WRITTEN BY THE SCRIPT (not by shell redirection)
    With `*>` in a scheduled-task action the output never reaches the file -- the task
    reports success and the log stays empty. The script appends its own log instead.

  USAGE
    pwsh -NoProfile -File .\maintenance-daily.ps1
    pwsh -NoProfile -File .\maintenance-daily.ps1 -DryRun
    pwsh -NoProfile -File .\maintenance-daily.ps1 -SkipCloud

  EXIT CODES
    0 = wrapper completed (check the log for each job's own verdict);
    1 = the log itself could not be written.

  FILE FORMAT
    ASCII only, LF line endings, no BOM (a scheduled script must survive PowerShell 5.1,
    which reads a BOM-less UTF-8 file as ANSI).
#>
[CmdletBinding()]
param(
  # Folder holding the child scripts and the log.
  [string]$ToolDir = $PSScriptRoot,

  # Log file. Empty = <ToolDir>\maintenance.log
  [string]$LogFile = '',

  # Interpreter used to launch the child scripts. Empty = auto (pwsh 7 when present,
  # otherwise the current PowerShell host, which is 5.1 under Task Scheduler).
  [string]$Pwsh = '',

  # Root scanned by prune-local-backups.ps1. Empty = that script's own default.
  [string]$BackupRoot = '',

  # Root scanned by prune-snapshots.ps1. Empty = skip the snapshot job.
  [string]$SnapshotRoot = '',

  # Repository trimmed by archive-old-versions.ps1. Empty = skip the cloud job.
  [string]$CloudRepo = '',

  # Retention windows.
  [int]$KeepBackupDays = 3,
  [int]$KeepSnapshotDays = 7,
  [int]$KeepCloudVersions = 20,

  # Only print what would happen; pass -DryRun through to the children.
  [switch]$DryRun,

  # Skip individual jobs.
  [switch]$SkipLocal,
  [switch]$SkipSnapshots,
  [switch]$SkipCloud
)

$ErrorActionPreference = 'Continue'

if (-not $ToolDir) { $ToolDir = (Get-Location).Path }
if (-not $LogFile) { $LogFile = Join-Path $ToolDir 'maintenance.log' }

# TECH NOTE: do not assume pwsh 7 exists on the target machine. Task Scheduler launches
# 5.1, and the child scripts are written to run on either, so fall back to the host.
if (-not $Pwsh) {
  $pwshCmd = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwshCmd) { $Pwsh = $pwshCmd.Source }
  else { $Pwsh = (Get-Process -Id $PID).Path }
}

function Write-Log([string]$Text) {
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $Text
  Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Invoke-Job {
  param(
    [string]$Label,
    [string]$ScriptPath,
    [string[]]$ScriptArgs,
    [string]$VerdictPattern,
    [string]$DetailPattern
  )

  if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Log ($Label + ': SKIP script not found: ' + $ScriptPath)
    return
  }

  $argv = @('-NoProfile', '-File', $ScriptPath) + $ScriptArgs
  try {
    $out = (& $Pwsh @argv 2>&1 | Out-String)
  } catch {
    Write-Log ($Label + ': EXCEPTION ' + $_.Exception.Message)
    return
  }

  $lines = @($out -split "`r?`n")
  $verdict = @($lines | Where-Object { $_ -match $VerdictPattern } | Select-Object -First 1)
  $detail = @($lines | Where-Object { $_ -match $DetailPattern })
  $joined = (@($detail) + @($verdict)) -join ' | '
  if (-not $joined) { $joined = 'no recognizable output' }
  Write-Log ($Label + ': ' + $joined)
}

Write-Log '--- maintenance start ---'
Write-Log ('interpreter : ' + $Pwsh)

if (-not $SkipLocal) {
  $a = @()
  if ($BackupRoot) { $a += @('-Root', $BackupRoot) }
  $a += @('-KeepDays', $KeepBackupDays.ToString())
  if ($DryRun) { $a += '-DryRun' }
  Invoke-Job -Label 'local' -ScriptPath (Join-Path $ToolDir 'prune-local-backups.ps1') `
    -ScriptArgs $a -VerdictPattern 'VERDICT' -DetailPattern '^(pruned|bak files|bak left)'
}

if (-not $SkipCloud) {
  if (-not $CloudRepo) {
    Write-Log 'cloud: SKIP (no -CloudRepo)'
  } else {
    $a = @('-Repo', $CloudRepo, '-Keep', $KeepCloudVersions.ToString())
    if ($DryRun) { $a += '-DryRun' }
    Invoke-Job -Label 'cloud' -ScriptPath (Join-Path $ToolDir 'archive-old-versions.ps1') `
      -ScriptArgs $a -VerdictPattern 'VERDICT' -DetailPattern '^(commits now|after|\.git size|ERROR:|WARN|ROLLBACK)'
  }
}

if (-not $SkipSnapshots) {
  if (-not $SnapshotRoot) {
    Write-Log 'snap : SKIP (no -SnapshotRoot)'
  } else {
    $a = @('-Root', $SnapshotRoot, '-KeepDays', $KeepSnapshotDays.ToString())
    if ($DryRun) { $a += '-DryRun' }
    Invoke-Job -Label 'snap' -ScriptPath (Join-Path $ToolDir 'prune-snapshots.ps1') `
      -ScriptArgs $a -VerdictPattern 'VERDICT' -DetailPattern '^(snapshots|pruned|FAILED)'
  }
}

Write-Log '--- maintenance end ---'

# Keep the log itself bounded: a log nobody reads is a log that grows forever.
if (Test-Path -LiteralPath $LogFile) {
  try {
    if ((Get-Item -LiteralPath $LogFile).Length -gt 204800) {
      $tail = Get-Content -LiteralPath $LogFile -Tail 300
      Set-Content -LiteralPath $LogFile -Value $tail -Encoding UTF8
    }
  } catch {
    Write-Output ('WARN could not trim log: ' + $_.Exception.Message)
    exit 1
  }
}

exit 0
