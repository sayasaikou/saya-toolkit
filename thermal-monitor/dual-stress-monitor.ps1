# dual-stress-monitor.ps1
# One-click CPU+GPU dual-stress monitor.
#   - reads MSI Afterburner shared memory every 2s for 15 min -> CSV
#   - prints a live GPU/CPU line so overheating is visible at a glance
#   - ALWAYS kills the stress tools at the end, plus an independent watchdog
#     timer, so the machine is safe even if this window is closed or the user walks away.

param([int]$Seconds = 900, [int]$IntervalMs = 2000)

$ErrorActionPreference = 'Continue'

$abExe    = 'D:\MSI Afterburner\MSIAfterburner.exe'
$monitor  = '$env:DSH_HOME\ab-monitor.exe'
$hid      = '$env:DSH_HOME\run-hidden.exe'
$killer   = '$env:DSH_HOME\stress-kill.ps1'
$psExe    = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$outDir   = '$env:DSH_WORKSPACE\双烤测试'
$seconds  = $Seconds
$interval = $IntervalMs
$graceSec = 1320    # watchdog: unconditional kill ~22 min after start

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
Write-Host '   双烤监测  (Afterburner 共享内存 -> CSV)' -ForegroundColor Cyan
Write-Host '==================================================' -ForegroundColor Cyan

# ---- 1) Afterburner ----
$ab = Get-Process MSIAfterburner -ErrorAction SilentlyContinue
if (-not $ab) {
    Write-Host '[1/4] Afterburner 未运行，启动中...' -ForegroundColor Yellow
    if (Test-Path $abExe) { Start-Process $abExe | Out-Null; Start-Sleep -Seconds 10; $ab = Get-Process MSIAfterburner -ErrorAction SilentlyContinue }
}
if (-not $ab) { Write-Host '[1/4] Afterburner 拉不起来，退出。' -ForegroundColor Red; Read-Host '回车关闭'; exit 1 }
Write-Host ("[1/4] Afterburner OK (pid={0})" -f $ab[0].Id) -ForegroundColor Green

# ---- 2) pre-clean: kill leftovers, arm the independent watchdog ----
$left = Stop-StressTools
if ($left.Count -gt 0) { Write-Host ("[2/4] 清掉残留烤机进程: {0}" -f ($left -join ', ')) -ForegroundColor Yellow }
else { Write-Host '[2/4] 无残留进程' -ForegroundColor Green }

if ((Test-Path $hid) -and (Test-Path $killer)) {
    & $hid $psExe -NoProfile -ExecutionPolicy Bypass -File $killer -DelaySeconds $graceSec | Out-Null
    Write-Host ("      安全闸已上：无论发生什么，{0} 分钟后强制关掉所有烤机程序" -f [int]($graceSec / 60)) -ForegroundColor DarkGray
}

# ---- 3) logging ----
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$csv = Join-Path $outDir ('双烤数据-{0}.csv' -f (Get-Date -Format 'yyyyMMdd-HHmm'))

Write-Host ''
Write-Host ('[3/4] 开始记录：每 {0} 秒一点，共 {1:N0} 分钟' -f ($interval / 1000), ($seconds / 60)) -ForegroundColor Green
Write-Host "      数据 -> $csv" -ForegroundColor DarkGray
Write-Host ''
Write-Host '   >>> 现在去图吧工具箱点【一键双烤】 <<<' -ForegroundColor Yellow
Write-Host ''
Write-Host '   你可以直接出门：15 分钟后自动停记录，并自动关掉烤机程序。' -ForegroundColor DarkGray
Write-Host ''

& $monitor $csv $seconds $interval
$code = $LASTEXITCODE

# ---- 4) stop everything ----
$killed = Stop-StressTools
Write-Host ''
Write-Host '==================================================' -ForegroundColor Cyan
Write-Host '[4/4] 收尾' -ForegroundColor Cyan
if ($killed.Count -gt 0) { Write-Host ("      已关闭烤机程序: {0}" -f ($killed -join ', ')) -ForegroundColor Yellow }
else { Write-Host '      无烤机进程需要关闭' -ForegroundColor Green }
Write-Host ("      exit={0}" -f $code)
Write-Host "数据文件: $csv" -ForegroundColor Green
if (Test-Path $csv) {
    $lines = (Get-Content $csv | Measure-Object -Line).Lines
    Write-Host ("      采样行数: {0}" -f ($lines - 1)) -ForegroundColor Green
}
Write-Host ''
Write-Host '回来跟大肥鱼说一句「双烤跑完了」就行。' -ForegroundColor Yellow
Write-Host ''
Read-Host '按回车关闭窗口'