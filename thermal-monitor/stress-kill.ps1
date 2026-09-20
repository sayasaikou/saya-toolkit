param([int]$DelaySeconds = 1320)
# stress-kill.ps1 - independent watchdog: after DelaySeconds, kill every stress tool.
# Launched hidden by dual-stress-monitor.ps1 so the box is safe even if that window dies.
Start-Sleep -Seconds $DelaySeconds
$names = @('cpuburner','gpushark','gpushark_x64','FurMark','furmark','FurMark_GUI','_fm2-gui')
$log = '$env:DSH_HOME\stress-kill.log'
$hit = @()
foreach ($n in $names) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; $hit += ($p.ProcessName + '(' + $p.Id + ')') } catch { }
    }
}
$line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  watchdog fired after ' + $DelaySeconds + 's  killed=[' + ($hit -join ',') + ']'
Add-Content -Path $log -Value $line -Encoding UTF8