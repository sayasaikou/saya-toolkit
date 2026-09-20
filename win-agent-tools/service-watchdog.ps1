# service-watchdog.ps1 -- keep-alive watchdog for a local launcher-backed web service.
#
# WHY: remote / mobile access only works while the service stays up, and nobody is sitting
# in front of the machine. Two jobs per run:
#   1) HEARTBEAT - write one line every run, so the log can prove whether the box really
#      kept running while the lid was closed / nobody was at the keyboard.
#   2) RESCUE    - if the port has no listener, start the launcher again and log it.
#
# Manual run:  powershell -NoProfile -ExecutionPolicy Bypass -File service-watchdog.ps1 -Once
#
# ASCII ONLY: Task Scheduler runs this under Windows PowerShell 5.1, which reads a
# BOM-less UTF-8 file as ANSI and dies on non-ASCII characters.
#
# PREREQUISITES
#   * -Launcher must point at the launcher executable and -LauncherProcess must match its
#     process name, otherwise the process part of the heartbeat is meaningless.
#   * Deployed as a repeating task (every few minutes, limited run level) whose action goes
#     through a windowless runner -- see fix-flash-tasks.ps1. A task action that starts
#     powershell.exe directly flashes a console window on every single run.
#   * BEFORE deliberately stopping the service for maintenance, disable this task. If it
#     runs during an update it can start a launcher against a half-built configuration,
#     which is how a 44-minute outage happens.
#
# NOTE ON JUDGEMENT: the exit code is always 0. The verdict lives in the log line
# (state=UP / RESCUED / FAILED); a FAILED line is the only one that needs a human.
[CmdletBinding()]
param(
  [switch]$Once,

  # Folder that holds the tools and the logs.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Launcher executable that starts the service.
  [string]$Launcher = 'C:\Program Files\dsh-launcher\DshWeb.exe',

  # Launcher process name (without .exe) used by the heartbeat.
  [string]$LauncherProcess = 'DshWeb',

  # Port the service must listen on.
  [int]$Port = 3080,

  # How many times a single run may try to relaunch before declaring FAILED.
  [int]$MaxRelaunch = 3,

  # Log file. Empty = <DshHome>\service-watchdog.log
  [string]$LogFile = ''
)

$Dsh         = $DshHome
$Log         = $LogFile
if (-not $Log) { $Log = Join-Path $Dsh 'service-watchdog.log' }
$LauncherLog = Join-Path $Dsh 'dsh-launcher\dsh.log'

function Write-W([string]$m) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File -FilePath $Log -Append -Encoding UTF8
}

function Get-BootStamp {
    # Uptime plus last-boot timestamp: tells 'same boot all along' apart from a reboot.
    # Without it, a gap in the heartbeat cannot be explained.
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $up = (Get-Date) - $os.LastBootUpTime
        return ('uptime=' + [string]::Format('{0}d{1:00}h{2:00}m', $up.Days, $up.Hours, $up.Minutes) +
                ' lastboot=' + $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm'))
    } catch { return 'uptime=unknown' }
}

function Test-DshPort {
    # TECH NOTE: TcpClient.ConnectAsync with a timeout is used instead of
    # Get-NetTCPConnection because it also proves something is actually ACCEPTING on the
    # port, not merely that a socket is in the Listen state. A half-dead service can hold
    # a listener and never answer, and that is exactly the failure this watchdog is for.
    try {
        $c = New-Object Net.Sockets.TcpClient
        $ok = $c.ConnectAsync('127.0.0.1', $Port).Wait(3000)
        $c.Close()
        return [bool]$ok
    } catch { return $false }
}

function Get-ServicePid {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
    if ($conn) { return [int]$conn.OwningProcess }
    return 0
}

function Get-LauncherPids {
    return @(Get-Process $LauncherProcess -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id })
}

function Start-DshWeb {
    if (-not (Test-Path $Launcher)) {
        Write-W ('ERROR launcher not found: ' + $Launcher)
        return $false
    }
    try {
        Start-Process $Launcher -ErrorAction Stop
        Write-W 'relaunch: started the launcher'
    } catch {
        Write-W ('relaunch FAILED: ' + $_.Exception.Message)
        return $false
    }
    for ($i = 1; $i -le 120; $i++) {
        Start-Sleep -Seconds 1
        if (Test-DshPort) { Write-W ('relaunch OK: port ' + $Port + ' listening after ' + $i + 's'); return $true }
    }
    Write-W 'relaunch: port never came up within 120s'
    return $false
}

# ------------------------------------------------------------------ main
$state = 'UP'
if (-not (Test-DshPort)) {
    $state = 'DOWN'
    Write-W ('ALERT: port ' + $Port + ' has no listener')
    $lps = Get-LauncherPids
    if ($lps.Count -gt 0) { Write-W ('   launcher still running: pid ' + ($lps -join ',')) }
    $started = $false
    for ($n = 1; $n -le $MaxRelaunch; $n++) {
        Write-W ('rescue attempt ' + $n + '/' + $MaxRelaunch)
        if (Start-DshWeb) { $started = $true; $state = 'RESCUED'; break }
        Start-Sleep -Seconds 10
    }
    if (-not $started) {
        $state = 'FAILED'
        Write-W 'RESULT: FAILED - service is down and relaunch did not help; needs a human'
    }
}

$svcPid = Get-ServicePid
$lps    = Get-LauncherPids
$tail   = @(Get-Content $LauncherLog -Tail 40 -ErrorAction SilentlyContinue)
# E1006 is filtered out on purpose: it is a known-benign launcher log entry, so counting it
# would drown the real ERROR lines and the heartbeat would lose its signal.
$err    = @($tail | Where-Object { $_ -match '"level":"ERROR"' -and $_ -notmatch 'E1006' })

Write-W ('HEARTBEAT state=' + $state +
         ' svcPid=' + $svcPid +
         ' launcher={' + ($lps -join ',') + '}' +
         ' recentLauncherErrors=' + $err.Count +
         ' ' + (Get-BootStamp))

if ($err.Count -gt 0) {
    Write-W '   recent launcher ERROR lines:'
    foreach ($e in $err) { Write-W ('   log> ' + $e) }
}

if ($Once) { Write-Output ('watchdog run complete: state=' + $state) }
