<#
  health-check.ps1 -- health probe for a DSH style local service, independent of the app

  It relies on nothing but PowerShell + HTTP, so it still works when the app itself is
  too broken to report anything about itself. Exit code is meant to be consumed by a
  scheduler or a watchdog.

  USAGE
    pwsh -NoProfile -File .\health-check.ps1           # human readable report
    pwsh -NoProfile -File .\health-check.ps1 -Quiet    # one summary line
    pwsh -NoProfile -File .\health-check.ps1 -Port 3080 -ProcessName DshWeb   # old layout

  EXIT CODES
    0 = healthy      1 = something needs attention

  WHY THIS SCRIPT AUTO-DETECTS (read this before editing)
    The same product shipped in two very different shapes, and a probe written for one
    silently reports ATTENTION forever on the other -- the classic "boy who cried wolf"
    failure, where a permanently red probe gets ignored exactly when it matters.

      launcher era : main process DshWeb, port 3080, and it wrote a log file that carried
                     the per-boot service token, so the page could be fetched and measured.
      desktop era  : main process "DeepSeek Harness" (Electron), port 19387. It keeps its
                     per-boot token INSIDE the app, so nothing outside can read it and the
                     page probe is simply not available.

    So: the layout is detected, the checks that cannot be done are reported as N/A (never
    as a failure), and -Port / -ProcessName stay available as manual overrides.

  CHECKS
    1. PORT     -- is the configured port listening, and which pid owns it
    2. PROCESS  -- is the expected main process alive
    3. FOOTPRINT-- age of a per-plugin stamp file (proves the plugin really loaded)
    4. PAGE     -- [legacy layout only] read the newest service token out of the log,
                   fetch the page with it, measure the raw byte length. The token itself is
                   NEVER printed -- only its length and the line number.
    5. TUNNEL   -- [optional] is a second port (e.g. a mobile tunnel) listening

  KNOWN BLIND SPOT (measured -- keep it in mind, it is the whole reason check 3 exists)
    A page probe only proves the shell booted, NOT that the page really rendered: during a
    blank-page incident caused by a client-side patch, the probe still reported HEALTHY.
    Client-side breakage is ultimately judged by a human opening the page. Measured
    reference: a healthy rawLen was about 2250, a blank page measured about 44.
    That is why the plugin footprint (check 3) carries more weight than the page probe:
    it is a filesystem fact, not a claim the service makes about itself.

  PREREQUISITES
    * -StampPlugin is optional: without it the footprint check reports N/A instead of
      failing, so the script is usable on any installation.
    * 127.0.0.1 must be reachable (it always is, unless the loopback itself is broken).

  FILE FORMAT
    ASCII only, LF line endings, no BOM (PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI,
    so a script a scheduler may launch has to stay pure ASCII).
    Dual-engine: parses and runs on both 5.1 and 7 (no ?? / ternary / [Type]::new()).
#>
[CmdletBinding()]
param(
  # Home folder of the installation.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Service port. 0 = auto-detect (19387 desktop era, else 3080).
  [int]$Port = 0,

  # Main process name (without .exe). Empty = auto-detect.
  [string]$ProcessName = '',

  # Profile folder that holds plugins. Empty = auto-detect (desktop, else web).
  [string]$ProfileName = '',

  # Optional plugin folder name whose _loaded.stamp is checked.
  # Empty = skip the footprint check (reported as N/A, not as a failure).
  [string]$StampPlugin = '',

  # [legacy layout] Log file carrying the 'token=...' line.
  # Empty = <DshHome>\dsh-launcher\dsh.log
  [string]$LauncherLog = '',

  # Optional second port expected to be listening (e.g. a mobile tunnel). 0 = skip.
  [int]$TunnelPort = 0,

  # A page probe shorter than this many characters is suspicious.
  [int]$MinProbeLen = 1000,

  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Dsh = $DshHome

# ---------------------------------------------------------------- layout detection
# TECH NOTE: detection is deliberately "look at what actually exists", never "look at a
# version number". The two layouts differ in which files exist, and files do not lie.
if (-not $ProfileName) {
  if (Test-Path (Join-Path $Dsh 'profiles\desktop')) { $ProfileName = 'desktop' }
  elseif (Test-Path (Join-Path $Dsh 'profiles\web')) { $ProfileName = 'web' }
  else { $ProfileName = 'desktop' }
}

if ($Port -le 0) {
  if ($ProfileName -eq 'web') { $Port = 3080 } else { $Port = 19387 }
}

if (-not $ProcessName) {
  if ($ProfileName -eq 'web') { $ProcessName = 'DshWeb' } else { $ProcessName = 'DeepSeek Harness' }
}

# The page probe needs a log that carries the service token. On the desktop layout that
# token never reaches the filesystem, so the check is off unless the caller points at a log.
if (-not $LauncherLog) { $LauncherLog = Join-Path $Dsh 'dsh-launcher\dsh.log' }
$pageProbeAvailable = ($ProfileName -eq 'web') -or (Test-Path $LauncherLog)

$StampF = ''
if ($StampPlugin) {
  $StampF = Join-Path $Dsh ('profiles\' + $ProfileName + '\plugins\' + $StampPlugin + '\_loaded.stamp')
}

$issues = @()

# ---- 1) port
$listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$svcPid = $null
if ($listener) { $svcPid = $listener.OwningProcess }
$portOk = [bool]$svcPid
if (-not $portOk) { $issues += ($Port.ToString() + ' has no listener (service is not up)') }

# ---- 2) main process
$proc = @(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue)
$procOk = ($proc.Count -gt 0)
if (-not $procOk) { $issues += ($ProcessName + ' is not running') }

# ---- 3) plugin footprint (the strongest signal available on the desktop layout)
$stampAgeH = $null
if ($StampF) {
  if (Test-Path $StampF) {
    $age = (Get-Date) - (Get-Item $StampF).LastWriteTime
    $stampAgeH = [math]::Round($age.TotalHours, 1)
    if ($stampAgeH -gt 48) {
      $issues += ('plugin footprint is ' + $stampAgeH + ' hours old -- the plugin may not have been loaded on this boot')
    }
  } else {
    $issues += ('plugin footprint file not found: ' + $StampF)
  }
}

# ---- 4) page probe (legacy layout only)
$rawLen = -1
$bootOk = $false
$tokNote = 'N/A (this layout does not expose the service token)'
if ($portOk -and $pageProbeAvailable) {
  if (Test-Path $LauncherLog) {
    $lines = @(Get-Content $LauncherLog -Tail 3000 -ErrorAction SilentlyContinue)
    $tok = $null
    $tokLine = -1
    $i = 0
    foreach ($l in $lines) {
      $i++
      if ($l -match 'token=(v?[A-Za-z0-9_\-]{20,})') { $tok = $matches[1]; $tokLine = $i }
    }
    if ($tok) {
      $tokNote = 'log lines scanned=' + $lines.Count + ', token found at line ' + $tokLine + ' (len=' + $tok.Length + ')'
      # TECH NOTE: the service token is a secret. Only its length and its line number are
      # ever logged -- never the value itself.
      try {
        $resp = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/?token=' + $tok) `
                                  -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $htmlStr = [string]$resp.Content
        $rawLen = $htmlStr.Length
        $bootOk = $htmlStr -match '__DSH_BOOT__'
      } catch {
        $tokNote += ' | fetch failed: ' + $_.Exception.Message
        $issues += 'page fetch failed (port is listening but the service did not answer)'
      }
      if ($rawLen -ge 0 -and -not $bootOk) {
        $tokNote += (' | probe inconclusive (rawLen=' + $rawLen + ') -- NOT counted as failure')
      } elseif ($rawLen -ge 0 -and $rawLen -lt $MinProbeLen) {
        $issues += ('page probe rawLen too small = ' + $rawLen + ' (healthy value was about 2250)')
      }
    } else {
      $tokNote = 'scanned ' + $lines.Count + ' tail lines, no token line found'
      $issues += 'no token line found in the tail of the log'
    }
  } else {
    $tokNote = 'log file missing: ' + $LauncherLog
    $issues += 'log file not found (-LauncherLog)'
  }
}

# ---- 5) optional second port
$tunnelUp = $null
if ($TunnelPort -gt 0) {
  $tunnelUp = [bool](Get-NetTCPConnection -LocalPort $TunnelPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $tunnelUp) { $issues += ($TunnelPort.ToString() + ' is not listening (expected by -TunnelPort)') }
}

# ---- output
$verdict = 'HEALTHY'
if ($issues.Count -gt 0) { $verdict = 'ATTENTION(' + $issues.Count + ')' }

if ($Quiet) {
  Write-Output ('health = ' + $verdict)
} else {
  Write-Host '=== service health check ===' -ForegroundColor Cyan
  Write-Host ('time        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  Write-Host ('layout      : ' + $ProfileName + ' (port ' + $Port + ', process "' + $ProcessName + '")')
  Write-Host ('port        : ' + $(if ($portOk) { 'UP  (pid ' + $svcPid + ')' } else { 'DOWN' }))
  Write-Host ('process     : ' + $(if ($procOk) { 'UP  (' + $proc.Count + ' process(es), pid ' + (($proc | Select-Object -First 3 | ForEach-Object { $_.Id }) -join ',') + ')' } else { 'DOWN' }))
  Write-Host ('plugin stamp: ' + $(if ($null -ne $stampAgeH) { ($stampAgeH.ToString() + ' hours ago') } elseif ($StampF) { 'MISSING' } else { 'N/A (no -StampPlugin)' }))
  Write-Host ('page probe  : ' + $(if ($rawLen -ge 0) { 'rawLen=' + $rawLen + '  boot=' + $bootOk } else { 'N/A' }))
  Write-Host ('  detail    : ' + $tokNote) -ForegroundColor DarkGray
  if ($null -ne $tunnelUp) {
    Write-Host ('port ' + $TunnelPort + '     : ' + $(if ($tunnelUp) { 'listening' } else { 'closed' })) -ForegroundColor DarkGray
  }
  if ($issues.Count -eq 0) {
    Write-Host 'VERDICT     : HEALTHY' -ForegroundColor Green
  } else {
    Write-Host ('VERDICT     : ' + $verdict) -ForegroundColor Yellow
    foreach ($x in $issues) { Write-Host ('   - ' + $x) -ForegroundColor Yellow }
  }
  Write-Host ''
  Write-Host 'Note: a green probe is not the same as a page that really renders.' -ForegroundColor DarkGray
}

if ($issues.Count -eq 0) { exit 0 } else { exit 1 }
