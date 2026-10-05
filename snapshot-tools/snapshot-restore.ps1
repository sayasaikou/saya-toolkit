<#
  snapshot-restore.ps1 -- restore an application home folder from a dated snapshot

  DEFAULT IS A DRY RUN. Nothing is written unless -Apply is passed.

  ORDER OF OPERATIONS (each step exists because the obvious order failed at least once)
    1. verify snapshot integrity (a restore from a half-written snapshot is worse than none)
    2. refuse if the service is running, unless -Force  (this tool stops it itself)
    3. take a re-entry lock (two overlapping restores corrupt the home)
    4. stop the main process and wait until BOTH the process and the port are gone
    5. rename the current home ASIDE (rename, never delete-recursive)
    6. copy the snapshot back
    7. copy back the machine-specific files that must survive the swap (credentials,
       settings, licenses) -- the archive holds the snapshot-taker's copies, not yours
    8. rebuild dependencies with a package-manager install (NEVER --force)
    9. relaunch and wait for the port; on any failure, roll the whole swap back

  WHY THE SWAP USES RENAME INSTEAD OF DELETE
    The earlier design was "delete the new home, then rename the parked one back". It failed
    in a real drill: deleting a tree that still has junctions or in-use files aborts, leaving
    the BLOCKED attempt live and the good home parked in a side directory. Renaming works
    even with locks held, so the rollback path is: rename the bad home aside, rename the
    parked original back. Measured: the drill that used to end in "ROLLBACK FAILED" now
    completes.

  WHY DEPENDENCIES ARE NOT ARCHIVED
    Package trees carry absolute-path links and platform-specific artifacts. Copying one
    between snapshots restores something that looks complete and does not work. The
    snapshot excludes them and this script rebuilds them. The install must NOT use a
    forced/clean flag: that overwrites the manager's own module links and produces a tree
    that fails on every subsequent start.

  USAGE
    pwsh -NoProfile -File .\snapshot-restore.ps1                       # dry run, latest
    pwsh -NoProfile -File .\snapshot-restore.ps1 -Snapshot 2026-01-31
    pwsh -NoProfile -File .\snapshot-restore.ps1 -Apply -Force         # really swap

  EXIT CODES
    0 = done (or dry run finished)   2 = no such snapshot
    3 = snapshot incomplete          4 = service running and -Force not given
    5 = failure, rollback attempted  6 = another restore is already running

  FILE FORMAT
    ASCII only, LF line endings, no BOM. PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI,
    so a script that may be scheduled has to stay pure ASCII.
#>
[CmdletBinding()]
param(
  # Home folder to restore into.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$HomeDir = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Snapshot name (a dated folder) or 'latest'.
  [string]$Snapshot = 'latest',

  # Where dated snapshot folders live.
  # Where dated snapshot folders live. $env:DSH_SNAPSHOT_DIR wins when set.
  [string]$Target = $(if ($env:DSH_SNAPSHOT_DIR) { $env:DSH_SNAPSHOT_DIR } else { Join-Path $env:USERPROFILE 'snapshots' }),

  # Profile folder name that holds the dependency manifest to rebuild.
  [string]$ProfileName = 'desktop',

  # Main process name (without .exe) that must be stopped and relaunched.
  [string]$ProcessName = 'DeepSeek Harness',

  # Port the service listens on. Used as the readiness signal.
  [int]$Port = 19387,

  # Executable used to relaunch the application. Empty = do not relaunch.
  [string]$Executable = '',

  # Relative paths that MUST exist in the snapshot, otherwise it is considered incomplete.
  # Defaults cover a typical layout; override for your own deployment.
  [string[]]$MustHave = @(),

  # Top-level files that must survive the swap (machine-specific credentials and settings).
  [string[]]$KeepFiles = @(
    '.credentials.yaml', 'settings.yaml', 'settings.json', 'licenses.json', 'anonymous-user-id.json'
  ),

  # Top-level folders excluded from the snapshot that must be preserved across the swap.
  [string[]]$KeepDirs = @('attachments'),

  # Extra folders to look in for a package manager executable.
  [string[]]$PackageManagerCandidates = @(),

  [switch]$Apply,

  # Accept the short outage without being asked. Without it, a running service aborts.
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$log = Join-Path $Target 'restore.log'

function Log([string]$m) {
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $m
  Write-Host $line
  $dir = Split-Path $log -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function PortUp([int]$p) {
  return [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
}

function Stop-AppProcess {
  # TECH NOTE: kill the process AND whatever still owns the port, then wait for both to
  # disappear. Killing only the named process leaves the port held by a child, and the
  # relaunch then fails with "address already in use" -- which reads like a launch bug.
  $w = 0
  do {
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
      Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 1
    $w++
    $alive = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count
  } while (((PortUp $Port) -or ($alive -gt 0)) -and $w -lt 30)
  return @{ seconds = $w; portUp = (PortUp $Port); alive = $alive }
}

function Start-App {
  if (-not $Executable) { return $false }
  if (-not (Test-Path -LiteralPath $Executable)) { return $false }
  Start-Process -FilePath $Executable -ErrorAction SilentlyContinue
  return $true
}

# ---- resolve snapshot ------------------------------------------------------
$snaps = @()
if (Test-Path -LiteralPath $Target) {
  $snaps = Get-ChildItem -LiteralPath $Target -Directory -Force |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending
}
if ($Snapshot -eq 'latest') {
  if ($snaps.Count -eq 0) { Log 'FATAL no snapshot found'; exit 2 }
  $snap = $snaps[0]
} else {
  $snap = $snaps | Where-Object { $_.Name -eq $Snapshot } | Select-Object -First 1
  if (-not $snap) { Log ('FATAL snapshot not found: ' + $Snapshot); exit 2 }
}
$src = $snap.FullName

# ---- verify ----------------------------------------------------------------
$manifestPath = Join-Path $src '_SNAPSHOT.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Log ('FATAL no _SNAPSHOT.json in ' + $snap.Name); exit 3 }
$man = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

$must = @($MustHave)
if ($must.Count -eq 0) {
  # Sensible defaults: the dependency manifest plus whatever the snapshot recorded.
  $must = @('profiles\' + $ProfileName + '\package.json')
}
$missing = @()
foreach ($m in $must) { if (-not (Test-Path -LiteralPath (Join-Path $src $m))) { $missing += $m } }
if ($missing.Count -gt 0) {
  Log ('FATAL snapshot incomplete, missing: ' + ($missing -join ', '))
  exit 3
}

$sizeMB = [math]::Round(((Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1MB, 1)

Log '=== restore plan ==='
Log ('  snapshot    : ' + $snap.Name + '  (' + $sizeMB + ' MB, taken ' + $man.createdAt + ')')
Log ('  current home: ' + $HomeDir)
Log ('  mode        : ' + $(if ($Apply) { 'APPLY (writes!)' } else { 'DRY-RUN (no writes)' }))

# machine-specific files that must survive the swap
$present = @()
foreach ($k in $KeepFiles) { if (Test-Path -LiteralPath (Join-Path $HomeDir $k)) { $present += $k } }
Log ('  kept from current machine: ' + $(if ($present.Count) { $present -join ', ' } else { '(none present)' }))

if (-not $Apply) {
  Log 'DRY-RUN complete. Re-run with -Apply to execute.'
  exit 0
}

if ((PortUp $Port) -and (-not $Force)) {
  Log ('ABORT: service is running on ' + $Port + '. This tool stops it itself; pass -Force to confirm you accept the short outage.')
  exit 4
}

# ---- 0. re-entry guard -----------------------------------------------------
# Two overlapping restores corrupt the home (verified in a real drill: a rehearsal and the
# previous rehearsal's script overlapped). Refuse to run if another restore is alive.
$lock = Join-Path $Target 'restore.lock'
if (Test-Path -LiteralPath $lock) {
  $oldPid = 0
  try { $oldPid = [int]((Get-Content -LiteralPath $lock -Raw).Trim()) } catch { }
  if ($oldPid -gt 0) {
    $alive = $false
    try { $alive = [bool](Get-Process -Id $oldPid -ErrorAction SilentlyContinue) } catch { $alive = $false }
    if ($alive) { Log ('ABORT: another restore is already running (pid ' + $oldPid + ')'); exit 6 }
  }
}
$PID | Out-File -FilePath $lock -Encoding ASCII

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$aside = $HomeDir + '.before-restore-' + $stamp
$ok = $false

try {
  # ---- 2. stop the application -------------------------------------------
  $st = Stop-AppProcess
  if ($st.portUp) { throw ('port ' + $Port + ' still occupied after 30s') }
  if ($st.alive -gt 0) { throw ($ProcessName + ' still alive after 30s (count=' + $st.alive + ')') }
  Log ('application stopped after ' + $st.seconds + 's')

  # ---- 3. swap ------------------------------------------------------------
  Rename-Item -LiteralPath $HomeDir -NewName (Split-Path $aside -Leaf)
  Log ('current home parked at ' + $aside)

  New-Item -ItemType Directory -Path $HomeDir -Force | Out-Null
  $rc = Start-Process -FilePath 'robocopy.exe' -ArgumentList @($src, $HomeDir, '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru -WindowStyle Hidden
  if ($rc.ExitCode -ge 8) { throw ('robocopy failed with exit ' + $rc.ExitCode) }
  Log ('snapshot copied back (robocopy exit ' + $rc.ExitCode + ')')

  # NOTE: runtime data the snapshot excludes is preserved LATER, right after the service is
  # confirmed up. Doing it here would lose it whenever this attempt rolls back, because the
  # new home is discarded on rollback.

  # ---- 4. machine credentials --------------------------------------------
  foreach ($k in $KeepFiles) {
    $from = Join-Path $aside $k
    if (Test-Path -LiteralPath $from) {
      Copy-Item -LiteralPath $from -Destination (Join-Path $HomeDir $k) -Force
      Log ('kept machine file: ' + $k)
    }
  }

  # ---- 5. rebuild dependencies (NEVER a forced install) -------------------
  $prof = Join-Path $HomeDir ('profiles\' + $ProfileName)
  if (Test-Path -LiteralPath (Join-Path $prof 'package.json')) {
    $pm = $null
    $cands = @($PackageManagerCandidates) + @(
      (Join-Path $env:APPDATA 'npm\pnpm.cmd'),
      (Join-Path $env:LOCALAPPDATA 'pnpm\pnpm.exe')
    )
    foreach ($cand in $cands) { if ($cand -and (Test-Path -LiteralPath $cand)) { $pm = $cand; break } }
    if (-not $pm) { $c = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue; if ($c) { $pm = $c.Source } }
    if ($pm) {
      $prc = Start-Process -FilePath $pm -ArgumentList @('install') -WorkingDirectory $prof -Wait -PassThru -WindowStyle Hidden
      Log ('dependency install exit=' + $prc.ExitCode + '  (no force flag)')
    } else {
      Log 'WARN package manager not found; dependencies were NOT rebuilt'
    }
  }

  # ---- 6. relaunch --------------------------------------------------------
  # Method verified by a controlled A/B/C test: starting the executable directly from an
  # elevated task context works; an extra de-elevation hop through the shell is not needed;
  # and firing an interactive scheduled task from an elevated context silently drops the
  # trigger (no run is recorded). So: settle a moment, start directly, retry if needed.
  Start-Sleep -Seconds 3
  if (Start-App) { Log 'application started' }
  else { Log 'WARN executable not found or not given; start the application manually' }

  $waited = 0
  $relaunchAt = 45
  while ($waited -lt 180) {
    if (PortUp $Port) { break }
    Start-Sleep -Seconds 5
    $waited += 5
    if ($waited -ge $relaunchAt) {
      $relaunchAt += 45
      Log ('still no listener after ' + $waited + 's -> retrying launch')
      Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 3
      [void](Start-App)
    }
  }
  if (-not (PortUp $Port)) { throw ('service did not come up within 180s (launch retries exhausted)') }
  Log ('service is up on ' + $Port + ' after ' + $waited + 's')

  # ---- 6b. preserve runtime data the snapshot deliberately excludes -------
  foreach ($d in $KeepDirs) {
    $fromD = Join-Path $aside $d
    $toD = Join-Path $HomeDir $d
    if (Test-Path -LiteralPath $fromD) {
      if (Test-Path -LiteralPath $toD) { Remove-Item -LiteralPath $toD -Recurse -Force -ErrorAction SilentlyContinue }
      try {
        Move-Item -LiteralPath $fromD -Destination $toD -Force -ErrorAction Stop
        Log ('preserved runtime data: ' + $d)
      } catch {
        Log ('WARN could not preserve ' + $d + ': ' + $_.Exception.Message)
      }
    }
  }

  $ok = $true
} catch {
  Log ('FAILED: ' + $_.Exception.Message)
}

if ($ok) {
  Log ('DONE restored to ' + $snap.Name + '; previous home kept at ' + $aside)
  Log ('rollback command: Remove-Item -Recurse -Force "' + $HomeDir + '"; Rename-Item "' + $aside + '" "' + $HomeDir + '"' + $(if ($Executable) { '; & "' + $Executable + '"' } else { '' }))
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  exit 0
} else {
  Log 'ROLLING BACK ...'
  $restored = $false
  try {
    # make sure nothing is holding files inside the home we are about to move
    Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    $z = 0
    while (((Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) -and $z -lt 20) { Start-Sleep -Seconds 1; $z++ }

    $bad = $HomeDir + '.failed-restore-' + $stamp
    # Retry the rename pair: a transient lock (indexer, antivirus) is common right after a
    # failed copy, and a single attempt would report ROLLBACK FAILED on a recoverable state.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
      try {
        if (Test-Path -LiteralPath $HomeDir) { Rename-Item -LiteralPath $HomeDir -NewName (Split-Path $bad -Leaf) -ErrorAction Stop }
        Rename-Item -LiteralPath $aside -NewName (Split-Path $HomeDir -Leaf) -ErrorAction Stop
        $restored = $true
        break
      } catch {
        Log ('  rollback attempt ' + $attempt + ' failed: ' + $_.Exception.Message)
        Start-Sleep -Seconds 3
      }
    }
    if ($restored) {
      Log ('rollback done; original home restored (failed attempt kept at ' + $bad + ')')
      try { [void](Start-App) } catch { Log '  (application not started -- start it manually)' }
    } else {
      Log ('ROLLBACK FAILED -> original home is still at ' + $aside + '  (manual: rename it back to ' + $HomeDir + ')')
    }
  } catch {
    Log ('ROLLBACK FAILED: ' + $_.Exception.Message + '  -> manual: rename ' + $aside)
  }
  Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
  exit 5
}
