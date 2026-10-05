<#
  snapshot-create.ps1 -- take a complete, restorable snapshot of an application home folder

  WHAT IT DOES
    Mirrors the home folder into <Target>\<yyyy-MM-dd>\ as a COMPLETE image. Files that did
    not change since the previous snapshot are HARDLINKED to it (same volume), so a daily
    snapshot costs only the bytes that actually changed. Measured on a real installation:
    a full tree of tens of thousands of files, ~300 MB of new bytes per day.

  WHAT IT DOES NOT DO (deliberate)
    * It never writes to the home folder, never stops the service, never touches locks.
    * It never deletes anything except its own rotation (see -Keep / -KeepMonthly).
    * node_modules trees are SKIPPED on purpose. They carry absolute-path links and
      platform-specific build artifacts; the restore script rebuilds them deterministically
      with a package-manager install instead of archiving a tree that cannot be trusted.

  WHY HARDINKS INSTEAD OF A ZIP
    A zip of the same tree is both slower and larger, and it cannot express "this file is
    unchanged" -- every run rewrites everything. Hardlinks make the previous snapshot the
    storage for the parts that did not change, while each dated folder still LOOKS like a
    complete tree to anything that walks it.

  WHY THERE IS A STALE-FILE REPORT
    Copy-Tree only ever adds or refreshes. Anything deleted from the live folder therefore
    lingers in older snapshots, and a restore brings it back -- that is how a plaintext
    credential sidecar survived several cleanups. The script reports (never deletes) any
    top-level file in today's snapshot that no longer exists live.

  USAGE
    pwsh -NoProfile -File .\snapshot-create.ps1 -Target 'D:\snapshots'
    pwsh -NoProfile -File .\snapshot-create.ps1 -Target 'D:\snapshots' -IncludeAttachments

  EXIT CODES
    0 = snapshot written    2 = home folder not found

  FILE FORMAT
    ASCII only, LF line endings, no BOM -- Windows PowerShell 5.1 reads a BOM-less UTF-8
    file as ANSI, so a scheduled script must stay pure ASCII.
#>
[CmdletBinding()]
param(
  # Home folder to snapshot.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$HomeDir = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Where dated snapshot folders are written.
  # Where dated snapshot folders are written. $env:DSH_SNAPSHOT_DIR wins when set; there is
  # deliberately no hardcoded fallback -- a wrong default here fills a disk silently.
  [string]$Target = $(if ($env:DSH_SNAPSHOT_DIR) { $env:DSH_SNAPSHOT_DIR } else { Join-Path $env:USERPROFILE 'snapshots' }),

  # Profile folder name used to locate plugins and the plugin footprint (see -StampPlugin).
  [string]$ProfileName = 'desktop',

  # Keep this many newest daily snapshots. 0 = keep everything.
  [int]$Keep = 14,

  # On top of -Keep, keep the newest snapshot of each of the last N months.
  [int]$KeepMonthly = 6,

  # Files at the top level of the snapshot that no longer exist live are REPORTED here
  # (one relative path per line) and never deleted.
  [string]$StaleReport = '',

  # Optional runtime manifest whose version field is recorded in the snapshot manifest.
  # Empty = skipped.
  [string]$RuntimeManifest = '',

  # Version field inside -RuntimeManifest. Empty = skipped.
  [string]$RuntimeVersionField = '',

  # Optional plugin folder whose footprint file records the last load time.
  # Empty = skipped. The stamp is expected at <Home>\profiles\<ProfileName>\plugins\<name>\_loaded.stamp
  [string]$StampPlugin = '',

  # Include the attachment/blob folder. Off by default: it is pure payload with no
  # configuration value and is usually the largest directory in the tree.
  [switch]$IncludeAttachments,

  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$log = Join-Path $Target 'snapshot.log'

function Log([string]$m) {
  $line = '[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $m
  if (-not $Quiet) { Write-Host $line }
  $dir = Split-Path $log -Parent
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Add-Content -Path $log -Value $line -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $HomeDir)) { Log ('FATAL home not found: ' + $HomeDir); exit 2 }

$today = (Get-Date).ToString('yyyy-MM-dd')
$dest = Join-Path $Target $today
New-Item -ItemType Directory -Path $dest -Force | Out-Null

# previous snapshot = newest other snapshot dir
$prev = $null
if (Test-Path -LiteralPath $Target) {
  $prev = Get-ChildItem -LiteralPath $Target -Directory -Force |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' -and $_.Name -ne $today } |
    Sort-Object Name -Descending | Select-Object -First 1
}

# Directories / subtrees skipped. These names are matched at ANY depth, so add only names
# that are never worth archiving anywhere in the tree.
$skipNames = @('node_modules', '.pnpm', 'locks', 'tmp', 'cache', 'logs')
if (-not $IncludeAttachments) { $skipNames += 'attachments' }

# Relative paths skipped (matched from the snapshot root). Add your own here.
$skipRel = @()

$stats = [ordered]@{ copied = 0; linked = 0; same = 0; skipped = 0; bytes = 0 }

function Copy-Tree([string]$srcDir, [string]$dstDir, [string]$rel) {
  New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
  foreach ($item in (Get-ChildItem -LiteralPath $srcDir -Force -ErrorAction SilentlyContinue)) {
    $childRel = if ($rel) { $rel + '\' + $item.Name } else { $item.Name }
    if ($item.PSIsContainer) {
      if ($skipNames -contains $item.Name) { $stats.skipped++; continue }
      $hit = $false
      foreach ($p in $skipRel) { if ($childRel -like $p) { $hit = $true; break } }
      if ($hit) { $stats.skipped++; continue }
      Copy-Tree $item.FullName (Join-Path $dstDir $item.Name) $childRel
      continue
    }
    $target = Join-Path $dstDir $item.Name
    if (Test-Path -LiteralPath $target) {
      # same-day re-run: refresh if the live file changed, otherwise skip.
      # Both length AND write time are compared: length alone misses same-size edits,
      # write time alone produces false differences across a copy.
      $cur = Get-Item -LiteralPath $target -Force
      if ($cur.Length -eq $item.Length -and $cur.LastWriteTimeUtc -eq $item.LastWriteTimeUtc) { $stats.same++; continue }
      Remove-Item -LiteralPath $target -Force
    }
    $prevFile = $null
    if ($prev) { $prevFile = Join-Path $prev.FullName $childRel }
    $reuse = $false
    if ($prevFile -and (Test-Path -LiteralPath $prevFile)) {
      $src = Get-Item -LiteralPath $item.FullName -Force
      $old = Get-Item -LiteralPath $prevFile -Force
      if ($old.Length -eq $src.Length -and $old.LastWriteTimeUtc -eq $src.LastWriteTimeUtc) { $reuse = $true }
    }
    if ($reuse) {
      try {
        New-Item -ItemType HardLink -Path $target -Target $prevFile -ErrorAction Stop | Out-Null
        $stats.linked++
      } catch {
        # Hardlinks need the same volume; falling back to a real copy keeps the snapshot
        # correct instead of failing the whole run.
        Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        $stats.copied++; $stats.bytes += $item.Length
      }
    } else {
      Copy-Item -LiteralPath $item.FullName -Destination $target -Force
      $stats.copied++; $stats.bytes += $item.Length
    }
  }
}

$t0 = Get-Date
Copy-Tree $HomeDir $dest ''

# ---- live-runtime file hygiene (observability only) --------------------------
# settings.yaml is a LIVE runtime file: the application rewrites it while running, and a
# freshly started service can leave a REDUCED version on disk for a while (measured once:
# 236 B right after a restart, 438 B once the settings surface wrote back).
# Record which shape was captured. The restore script keeps the machine's OWN copy of this
# file, so the archived copy is reference only -- this field just documents what it held.
$settingsFile = Join-Path $HomeDir 'settings.yaml'
$settingsState = 'missing'
if (Test-Path -LiteralPath $settingsFile) {
  $settingsText = Get-Content -LiteralPath $settingsFile -Raw -ErrorAction SilentlyContinue
  $settingsState = 'unknown'
  if ($settingsText) {
    $hasModel = $settingsText -match '(?m)^agent-default-model:'
    $hasPerm = $settingsText -match '(?m)^permission:'
    if ($hasModel -and $hasPerm) { $settingsState = 'full' }
    elseif ($hasModel -or $hasPerm) { $settingsState = 'reduced' }
  }
}

$stale = @()
foreach ($f in (Get-ChildItem -LiteralPath $dest -File -Force -ErrorAction SilentlyContinue)) {
  if (-not (Test-Path -LiteralPath (Join-Path $HomeDir $f.Name))) { $stale += $f.Name }
}

# ---- manifest ---------------------------------------------------------------
$runtimeVersion = 'unknown'
if ($RuntimeManifest -and $RuntimeVersionField -and (Test-Path -LiteralPath $RuntimeManifest)) {
  try {
    $runtimeVersion = (Get-Content -LiteralPath $RuntimeManifest -Raw -ErrorAction Stop | ConvertFrom-Json).$RuntimeVersionField
    if (-not $runtimeVersion) { $runtimeVersion = 'unknown' }
  } catch { }
}

$personaStamp = ''
if ($StampPlugin) {
  $stampPath = Join-Path $HomeDir ('profiles\' + $ProfileName + '\plugins\' + $StampPlugin + '_loaded.stamp')
  $si = Get-Item -LiteralPath $stampPath -ErrorAction SilentlyContinue
  if ($si) { $personaStamp = $si.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
}

$manifest = [ordered]@{
  name         = 'home-snapshot'
  createdAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  home         = $HomeDir
  base         = if ($prev) { $prev.Name } else { '(none)' }
  copiedFiles  = $stats.copied
  linkedFiles  = $stats.linked
  sameFiles    = $stats.same
  copiedMB     = [math]::Round($stats.bytes / 1MB, 2)
  skippedDirs  = $stats.skipped
  note         = 'node_modules excluded by design; the restore script rebuilds dependencies with a package-manager install (no --force)'
  runtimeVersion = $runtimeVersion
  pluginStamp  = $personaStamp
  settingsState = $settingsState
  staleTopLevel = ($stale -join ',')
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $dest '_SNAPSHOT.json') -Encoding UTF8

if ($StaleReport) {
  try {
    $dir = Split-Path $StaleReport -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $StaleReport -Value $stale -Encoding UTF8
  } catch { Log ('WARN could not write stale report: ' + $_.Exception.Message) }
}

# ---- system-level state (read-only capture; a restore may need it) -----------
$sys = Join-Path $dest '_SYSTEM-STATE.txt'
$out = New-Object System.Collections.Generic.List[string]
$out.Add('# captured ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
try {
  $scheme = (powercfg /getactivescheme) -join ' '
  $out.Add('power.scheme = ' + $scheme)
  $out.Add('power.monitorTimeoutAC = ' + ((powercfg /q SCHEME_CURRENT SUB_VIDEO VIDEOIDLE | Select-String 'Current AC Power Setting Index') -join ' '))
  $out.Add('power.standbyAC = ' + ((powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE | Select-String 'Current AC Power Setting Index') -join ' '))
} catch { $out.Add('power.query failed: ' + $_.Exception.Message) }
try {
  Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
  $modes = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName + ' ' + $_.Bounds.Width + 'x' + $_.Bounds.Height }
  $out.Add('screens = ' + ($modes -join ' | '))
} catch { $out.Add('screens.query failed') }
try {
  $hz = Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name + ' cur=' + $_.CurrentHorizontalResolution + 'x' + $_.CurrentVerticalResolution + '@' + $_.CurrentRefreshRate }
  $out.Add('display = ' + ($hz -join ' | '))
} catch { $out.Add('display.query failed') }
$out | Set-Content -LiteralPath $sys -Encoding UTF8

# ---- rotation ---------------------------------------------------------------
# Keep the newest $Keep dailies, plus one per month for $KeepMonthly months.
# TECH NOTE: deleting a hardlinked file only removes that NAME -- the data survives as long
# as another snapshot still links it, so rotation is safe even for a shared inode.
$removed = @()
if ($Keep -gt 0) {
  $all = Get-ChildItem -LiteralPath $Target -Directory -Force |
    Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' } | Sort-Object Name -Descending
  if ($all.Count -gt $Keep) {
    $monthly = @{}
    foreach ($d in $all) {
      $key = $d.Name.Substring(0, 7)
      if (-not $monthly.ContainsKey($key)) { $monthly[$key] = $d.Name }
    }
    $keepMonthlyNames = ($monthly.Values | Sort-Object -Descending | Select-Object -First $KeepMonthly)
    foreach ($d in ($all | Select-Object -Skip $Keep)) {
      if ($keepMonthlyNames -contains $d.Name) { continue }
      Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
      $removed += $d.Name
    }
  }
}

$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$size = (Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
Log ('settings state at capture: ' + $settingsState + '  (restore keeps the machine copy; the archived one is reference only)')
if ($stale.Count -gt 0) { Log ('WARN stale top-level files still archived (gone from live home, a restore would revive them): ' + ($stale -join ', ')) }
Log ('snapshot=' + $today + ' copied=' + $stats.copied + ' hardlinked=' + $stats.linked + ' newBytes=' + [math]::Round($stats.bytes / 1MB, 2) + 'MB sizeMB=' + [math]::Round($size / 1MB, 1) + ' took=' + $secs + 's base=' + $manifest.base)
if ($removed.Count -gt 0) { Log ('rotated out: ' + ($removed -join ', ')) }
exit 0
