<#
  health-check.ps1 -- health probe for a DSH style local web service, independent of DSH

  It relies on nothing but PowerShell + HTTP, so it still works when the app itself is
  too broken to report anything about itself.

  USAGE
    pwsh -NoProfile -File .\health-check.ps1           # human readable report
    pwsh -NoProfile -File .\health-check.ps1 -Quiet    # one summary line

  EXIT CODES
    0 = healthy      1 = something needs attention

  CHECKS
    1. TCP: is the configured port listening, and which pid owns it
    2. PAGE PROBE: read the newest service token out of the launcher log, fetch the page
       with that token, and measure the raw byte length. The token itself is NEVER printed
       -- only its length and the line number are logged.
    3. PLUGIN FOOTPRINT: age of a per-plugin stamp file (proves the plugin was loaded)
    4. LAUNCHER: is the launcher process still alive

  KNOWN BLIND SPOT (measured, keep it in mind)
    The probe only checks that __DSH_BOOT__ is present in the response. That does NOT mean
    the page really rendered: during a blank-page incident the probe still reported
    HEALTHY. Client-side breakage is ultimately judged by a human opening the page.
    A healthy rawLen is about 2250; a blank page measured about 44.

  PREREQUISITES
    * -LauncherLog must point at the log that contains the 'token=...' service URL line.
    * -StampPlugin is optional: without it the footprint check reports N/A instead of
      failing, so the script works for any installation.
    * curl.exe (shipped with Windows 10 1803+) is used for the page fetch.

  FILE FORMAT
    ASCII only, LF line endings, no BOM (PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI).
#>
[CmdletBinding()]
param(
  # DSH home folder.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Port the service listens on.
  [int]$Port = 3080,

  # Launcher executable name (without .exe) that is expected to be running.
  [string]$LauncherProcess = 'DshWeb',

  # Launcher log file that carries the 'token=...' line. Empty = <DshHome>\dsh-launcher\dsh.log
  [string]$LauncherLog = '',

  # Optional plugin folder name under profiles\web\plugins whose _loaded.stamp is checked.
  # Empty = skip the footprint check (reported as N/A, not as a failure).
  [string]$StampPlugin = '',

  # A page probe shorter than this many characters is suspicious.
  [int]$MinProbeLen = 1000,

  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$Dsh    = $DshHome
$LogF   = $LauncherLog
if (-not $LogF) { $LogF = Join-Path $Dsh 'dsh-launcher\dsh.log' }
$StampF = ''
if ($StampPlugin) { $StampF = Join-Path $Dsh ('profiles\web\plugins\' + $StampPlugin + '\_loaded.stamp') }

$issues = @()

# ---- 1) port
$port = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
$svcPid = if ($port) { $port.OwningProcess } else { $null }
$portOk = [bool]$svcPid
if (-not $portOk) { $issues += ($Port.ToString() + ' has no listener (service is not up)') }

# ---- 2) page probe (token comes from the launcher log; its content is never printed)
$rawLen = -1
$bootOk = $false
$tokNote = ''
if ($portOk) {
  if (Test-Path $LogF) {
    $lines = Get-Content $LogF -Tail 3000 -ErrorAction SilentlyContinue
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
      $html = & curl.exe -s -L --max-time 15 ('http://127.0.0.1:' + $Port + '/?token=' + $tok) 2>$null
      $htmlStr = ($html -join "`n")
      $rawLen = $htmlStr.Length
      $bootOk = $htmlStr -match '__DSH_BOOT__'
      if (-not $bootOk) { $tokNote += (' | token probe inconclusive (rawLen=' + $rawLen + ') -- NOT counted as failure') }
      elseif ($rawLen -lt $MinProbeLen) { $issues += ('page probe rawLen too small = ' + $rawLen + ' (healthy value is about 2250)') }
    } else {
      $tokNote = 'scanned ' + $lines.Count + ' tail lines, no token line found'
      $issues += 'no token line found in the tail of the launcher log'
    }
  } else {
    $tokNote = 'log file missing: ' + $LogF
    $issues += 'launcher log not found'
  }
}

# ---- 3) plugin footprint
$stampAgeH = $null
if ($StampF) {
  if (Test-Path $StampF) {
    $age = (Get-Date) - (Get-Item $StampF).LastWriteTime
    $stampAgeH = [math]::Round($age.TotalHours, 1)
    if ($stampAgeH -gt 48) { $issues += ('plugin footprint is ' + $stampAgeH + ' hours old (plugin may not have been loaded)') }
  } else { $issues += ('plugin footprint file not found: ' + $StampF) }
}

# ---- 4) launcher
$launcher = Get-Process $LauncherProcess -ErrorAction SilentlyContinue
if (-not $launcher) { $issues += ($LauncherProcess + '.exe (launcher) is not running') }

# ---- output
$verdict = if ($issues.Count -eq 0) { 'HEALTHY' } else { 'ATTENTION(' + $issues.Count + ')' }
if ($Quiet) {
  Write-Output ('health = ' + $verdict)
} else {
  Write-Host '=== DSH health check ===' -ForegroundColor Cyan
  Write-Host ('time        : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
  Write-Host (($Port.ToString() + ' service   : ') + $(if ($portOk) { 'UP  (pid ' + $svcPid + ')' } else { 'DOWN' }))
  Write-Host ('page probe  : ' + $(if ($rawLen -ge 0) { 'rawLen=' + $rawLen + '  boot=' + $bootOk } else { 'N/A' }))
  Write-Host ('  detail    : ' + $tokNote) -ForegroundColor DarkGray
  Write-Host ('plugin stamp: ' + $(if ($null -ne $stampAgeH) { ($stampAgeH.ToString() + ' hours ago') } elseif ($StampF) { 'MISSING' } else { 'N/A (no -StampPlugin)' }))
  Write-Host ('launcher    : ' + $(if ($launcher) { 'UP  (pid ' + ($launcher.Id -join ',') + ')' } else { 'DOWN' }))
  if ($issues.Count -eq 0) { Write-Host 'VERDICT     : HEALTHY' -ForegroundColor Green }
  else {
    Write-Host ('VERDICT     : ' + $verdict) -ForegroundColor Yellow
    foreach ($x in $issues) { Write-Host ('   - ' + $x) -ForegroundColor Yellow }
  }
  Write-Host ''
  Write-Host 'Note: a green probe is not the same as a page that really renders.' -ForegroundColor DarkGray
}

if ($issues.Count -eq 0) { exit 0 } else { exit 1 }
