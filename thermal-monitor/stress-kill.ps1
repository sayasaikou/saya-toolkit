# stress-kill.ps1
# Independent safety timer for a dual-stress run: after -DelaySeconds, terminate every
# known stress tool. It is launched hidden by dual-stress-monitor.ps1 with a deadline
# longer than the sampling window, so the machine is safe even if that monitor window
# is closed, crashes, or the operator walks away.

param(
    # Seconds to wait before the unconditional kill.
    [int]$DelaySeconds = 1320,

    # Where the one-line audit record is appended. Default: a per-user file under %TEMP%.
    [string]$LogFile = (Join-Path $env:TEMP 'stress-kill.log')
)

# Process names of common stress tools; extend for your own tooling.
$names = @('cpuburner','gpushark','gpushark_x64','FurMark','furmark','FurMark_GUI','_fm2-gui')

Start-Sleep -Seconds $DelaySeconds

$hit = @()
foreach ($n in $names) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $hit += ($p.ProcessName + '(' + $p.Id + ')') } catch { }
    }
}

$line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  watchdog fired after ' + $DelaySeconds + 's  killed=[' + ($hit -join ',') + ']'
Add-Content -Path $LogFile -Value $line -Encoding UTF8
