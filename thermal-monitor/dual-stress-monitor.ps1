# dual-stress-monitor.ps1
# One-click CPU+GPU dual-stress monitor.
#
#   - samples MSI Afterburner shared memory every N ms into a CSV
#   - prints a live GPU/CPU line so overheating is visible at a glance
#   - always terminates the stress tools when the run ends, and arms an
#     independent watchdog timer before it starts, so the machine is safe even
#     if this window is closed or the operator walks away.
#
# Prerequisites:
#   - ab-monitor.exe  (reads the Afterburner shared memory; see this folder)
#   - run-hidden.exe  (windowless launcher; see ../win-agent-tools)
#   - stress-kill.ps1 (unconditional killer used by the watchdog timer)
#   - MSI Afterburner installed; set -AfterburnerExe to its real location.

param(
    # Sampling window in seconds.
    [int]$Seconds = 900,

    # Sampling interval in milliseconds.
    [int]$IntervalMs = 2000,

    # Folder holding ab-monitor.exe, run-hidden.exe and stress-kill.ps1.
    [string]$ToolDir = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { $PSScriptRoot }),

    # Folder that receives the CSV output.
    [string]$OutDir = $(if ($env:DSH_WORKSPACE) { $env:DSH_WORKSPACE } else { $PSScriptRoot }),

    # MSI Afterburner executable, started when it is not already running.
    [string]$AfterburnerExe = 'C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe',

    # Unconditional kill deadline for the independent watchdog timer, in seconds.
    [int]$WatchdogSeconds = 1320
)

$ErrorActionPreference = 'Continue'

$monitor  = Join-Path $ToolDir 'ab-monitor.exe'
$hid      = Join-Path $ToolDir 'run-hidden.exe'
$killer   = Join-Path $ToolDir 'stress-kill.ps1'
$psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$seconds  = $Seconds
$interval = $IntervalMs
$graceSec = $WatchdogSeconds

# Process names of common stress tools; extend for your own tooling.
$stressNames = @('cpuburner','gpushark','gpushark_x64','FurMark','furmark','FurMark_GUI','_fm2-gui')

function Stop-StressTools {
    $hit = @()
    foreach ($n in $stressNames) {
        $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $hit += ($p.ProcessName + '(' + $p.Id + ')') } catch { }
        }
    }
    return $hit
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '   Dual-stress monitor (Afterburner shared memory -> CSV)' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

# ---- 1) Afterburner ----
$ab = Get-Process MSIAfterburner -ErrorAction SilentlyContinue
if (-not $ab) {
    Write-Host '[1/4] Afterburner is not running; starting it...' -ForegroundColor Yellow
    if (Test-Path $AfterburnerExe) { Start-Process $AfterburnerExe | Out-Null; Start-Sleep -Seconds 10; $ab = Get-Process MSIAfterburner -ErrorAction SilentlyContinue }
}
if (-not $ab) { Write-Host '[1/4] Afterburner could not be started; aborting.' -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 }
Write-Host ("[1/4] Afterburner OK (pid={0})" -f $ab[0].Id) -ForegroundColor Green

# ---- 2) pre-clean: kill leftovers, arm the independent watchdog ----
$left = Stop-StressTools
if ($left.Count -gt 0) { Write-Host ("[2/4] terminated leftover stress processes: {0}" -f ($left -join ', ')) -ForegroundColor Yellow }
else { Write-Host '[2/4] no leftover stress processes' -ForegroundColor Green }

if ((Test-Path $hid) -and (Test-Path $killer)) {
    & $hid $psExe -NoProfile -ExecutionPolicy Bypass -File $killer -DelaySeconds $graceSec | Out-Null
    Write-Host ("      safety timer armed: all stress processes are force-terminated after {0} min no matter what" -f [int]($graceSec / 60)) -ForegroundColor DarkGray
}

# ---- 3) logging ----
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$csv = Join-Path $OutDir ('dual-stress-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmm'))

Write-Host ''
Write-Host ('[3/4] recording: one sample every {0} s for {1:N0} min' -f ($interval / 1000), ($seconds / 60)) -ForegroundColor Green
Write-Host "      output -> $csv" -ForegroundColor DarkGray
Write-Host ''
Write-Host '   >>> Start your stress tool now <<<' -ForegroundColor Yellow
Write-Host ''
Write-Host '   The run stops by itself and terminates the stress tools; you can leave.' -ForegroundColor DarkGray
Write-Host ''

& $monitor $csv $seconds $interval
$code = $LASTEXITCODE

# ---- 4) stop everything ----
$killed = Stop-StressTools
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '[4/4] finishing' -ForegroundColor Cyan
if ($killed.Count -gt 0) { Write-Host ("      terminated stress processes: {0}" -f ($killed -join ', ')) -ForegroundColor Yellow }
else { Write-Host '      no stress process needed terminating' -ForegroundColor Green }
Write-Host ("      exit={0}" -f $code)
Write-Host "data file: $csv" -ForegroundColor Green
if (Test-Path $csv) {
    $lines = (Get-Content $csv | Measure-Object -Line).Lines
    Write-Host ("      sample rows: {0}" -f ($lines - 1)) -ForegroundColor Green
}
Write-Host ''
Read-Host 'Press Enter to close'
