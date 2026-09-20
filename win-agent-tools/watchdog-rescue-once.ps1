# watchdog-rescue-once.ps1 -- one-shot rescue that runs after a maintenance window.
#
# WHAT IT DOES (in this order)
#   1) re-enable the watchdog task, in case the maintenance script died before its
#      finally block could put it back
#   2) make sure the service is listening again; start the launcher if it is not
#   3) delete its own scheduled task, so no zombie task is left behind
#
# WHY IT EXISTS: while files are being swapped the watchdog has to be silenced, otherwise
# it races the maintenance (it probes the port every few minutes and can start a launcher
# against a half-built configuration). If the maintenance script is then killed -- crash,
# reboot, closed window -- nothing re-enables the watchdog and the service simply stays
# down until a human notices. This task is the net under that window.
#
# ASCII ONLY (PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI and dies on non-ASCII).
#
# HOW TO ARM IT (register it a few minutes before the maintenance starts)
#   $dsh = Join-Path $env:USERPROFILE '.dsh'
#   $act = New-ScheduledTaskAction -Execute (Join-Path $dsh 'run-hidden.exe') `
#            -Argument ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dsh 'watchdog-rescue-once.ps1') + '"')
#   $set = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
#   Register-ScheduledTask -TaskName DSH_WatchdogRescue_Once -Action $act -Settings $set -Force
#   Start-ScheduledTask DSH_WatchdogRescue_Once
#
# PREREQUISITES
#   * Enabling and disabling another task usually needs an elevated token; if the task
#     action is not elevated, step 1 is logged as a failure and steps 2-3 still run.
#   * -WatchdogTask and -SelfTaskName must match the names you actually registered.
#   * The script writes its own log file -- never rely on a task action's '>' redirect,
#     that redirect does not land on disk in a scheduled context.
#
# LOG: <DshHome>\watchdog-rescue.log
[CmdletBinding()]
param(
  # Folder that holds the tools and the logs.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # How long to wait before the rescue runs. Must outlast the maintenance window that
  # silences the watchdog.
  [int]$DelaySeconds = 480,

  # Watchdog task that must end up enabled.
  [string]$WatchdogTask = 'DSH_Watchdog',

  # This script's own one-shot task, removed at the end. Empty = do not remove anything.
  [string]$SelfTaskName = 'DSH_WatchdogRescue_Once',

  # Launcher executable used when the service is down.
  [string]$Launcher = 'C:\Program Files\dsh-launcher\DshWeb.exe',

  # Port the service must listen on.
  [int]$Port = 3080,

  # Log file. Empty = <DshHome>\watchdog-rescue.log
  [string]$LogFile = ''
)

$Log = $LogFile
if (-not $Log) { $Log = Join-Path $DshHome 'watchdog-rescue.log' }
function W($m) { ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) | Out-File -FilePath $Log -Append -Encoding UTF8 }

W 'rescue check start'
Start-Sleep -Seconds $DelaySeconds

# 1) re-enable the watchdog if it was left disabled
try {
    $t = Get-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue
    if ($t -and $t.State -eq 'Disabled') { Enable-ScheduledTask -TaskName $WatchdogTask | Out-Null; W 'watchdog was DISABLED -> enabled' }
    else { W ('watchdog state = ' + $(if ($t) { $t.State } else { 'MISSING' })) }
} catch { W ('watchdog check failed: ' + $_.Exception.Message) }

# 2) service must be listening again
try {
    if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
        W ('port ' + $Port + ' down -> starting launcher')
        Start-Process $Launcher
        for ($i = 1; $i -le 150; $i++) { Start-Sleep -Seconds 1; if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) { W ('service up after ' + $i + ' s'); break } }
    } else { W ('port ' + $Port + ' listening - ok') }
} catch { W ('port check failed: ' + $_.Exception.Message) }

# 3) remove this one-shot task. TECH NOTE: unregistering the task that is *currently
# running* is queued by Task Scheduler until the run ends, so a leftover task right after
# this line is normal -- check again a moment later before assuming the removal failed.
if ($SelfTaskName) {
    try { Unregister-ScheduledTask -TaskName $SelfTaskName -Confirm:$false; W 'rescue task unregistered' } catch { W ('self-remove failed: ' + $_.Exception.Message) }
} else { W 'self-remove skipped (-SelfTaskName is empty)' }
W 'rescue check end'
