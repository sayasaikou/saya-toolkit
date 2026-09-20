# restart-verify.ps1 -- delayed restart of a local service plus post-restart verification.
#
# WHY THE DELAY + A SEPARATE PROCESS: a restart kills the very service that hosts the
# assistant session, so the restart has to be queued with a delay and the verification
# has to run in a process that is not a child of the thing it restarts.
#
# Queue it as a HIDDEN one-shot scheduled task, for example:
#
#   $dsh = Join-Path $env:USERPROFILE '.dsh'
#   $act = New-ScheduledTaskAction -Execute (Join-Path $dsh 'run-hidden.exe') `
#            -Argument ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dsh 'restart-verify.ps1') + '" -Delay 150')
#   $pri = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
#   $set = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20)
#   Register-ScheduledTask -TaskName DSH_RestartVerifyOnce -Action $act -Principal $pri -Settings $set -Force
#   Start-ScheduledTask DSH_RestartVerifyOnce
#
# WHY -Hidden + a windowless runner (measured lesson): a plain 'cmd.exe /c powershell ...'
# action opens a VISIBLE console window that stays up for the whole delay. A user closed
# that window and the verification died halfway (the restart itself was fine). No window,
# no accident.
#
# Do NOT use -RunLevel Highest here. While the service runs non-elevated (medium integrity),
# registering a highest-run-level task is denied; the default limited level can still kill
# and restart a process owned by the same user.
#
# ASCII ONLY -- Task Scheduler runs this under Windows PowerShell 5.1.
#
# PREREQUISITES
#   * -RestartScript (default <DshHome>\dsh-restart.ps1) exists and does: stop launcher ->
#     free the port -> start launcher -> poll until the port answers.
#   * The script unregisters its own one-shot task at the end, so a leftover task means it
#     never reached the end -- check the log before re-running.
#
# LOG: <DshHome>\restart-verify.log
[CmdletBinding()]
param(
  # Seconds to wait before touching the service (long enough for the caller to finish).
  [int]$Delay = 60,

  # Folder that holds the DSH tools.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Restart implementation. Empty = <DshHome>\dsh-restart.ps1
  [string]$RestartScript = '',

  # TCP port the service must listen on after the restart.
  [int]$Port = 3080,

  # Launcher log scanned for the token line and the page-probe result.
  # Empty = <DshHome>\dsh-launcher\dsh.log
  [string]$LauncherLog = '',

  # Name of the one-shot task this script removes when it is done. Empty = do not touch
  # any task (useful when running the script by hand).
  [string]$SelfTaskName = 'DSH_RestartVerifyOnce',

  # Optional plugin footprint file to timestamp, to prove the plugin was loaded after the
  # restart. Empty = skip. Example: <DshHome>\profiles\web\plugins\<plugin>\_loaded.stamp
  [string]$StampFile = '',

  # Optional client-bundle patch checks. Each entry is a hashtable:
  #   @{ Path = '<built bundle file>'; MustContain = '<marker>'; MustNotContain = '<marker>' }
  # Both marker keys are optional. Empty = no patch checks are performed.
  [hashtable[]]$PatchChecks = @()
)

$ErrorActionPreference = 'Continue'
$logPath = Join-Path $DshHome 'restart-verify.log'

function Say([string]$m) {
  Add-Content -Path $logPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8
}

if (-not $RestartScript) { $RestartScript = Join-Path $DshHome 'dsh-restart.ps1' }
if (-not $LauncherLog) { $LauncherLog = Join-Path $DshHome 'dsh-launcher\dsh.log' }
$llog = $LauncherLog

Say ('=== restart-verify requested (delay=' + $Delay + 's) ===')
Start-Sleep -Seconds $Delay

if (Test-Path $RestartScript) {
  Say 'handing over to the restart script'
  # TECH NOTE: call Windows PowerShell 5.1 explicitly. The scheduled task may host a
  # different host, and a restart script that needs to run under the desktop session is
  # best kept on the interpreter that was tested.
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $RestartScript
} else {
  Say ('ABORT: restart script missing: ' + $RestartScript)
  exit 2
}

$up = $false
for ($i = 1; $i -le 40; $i++) {
  Start-Sleep -Seconds 3
  if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Say ('port ' + $Port + ' listening again after ~' + ($i * 3) + 's')
    $up = $true
    break
  }
}
if (-not $up) { Say ('ABORT: port ' + $Port + ' never came back'); exit 3 }

Say 'waiting 25s for launcher boot + page probe'
Start-Sleep -Seconds 25

$tok = $null
$rawLen = $null
try {
  # TECH NOTE: the token is a secret, so it is used but never written to the log.
  $m = Select-String -Path $llog -Pattern 'token=([A-Za-z0-9_\-]+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
  if ($m) { $tok = $m.Matches[0].Groups[1].Value }
  $p = Select-String -Path $llog -Pattern 'page probe: round done \(rawLen=([0-9]+)\)' -ErrorAction SilentlyContinue | Select-Object -Last 1
  if ($p) { $rawLen = $p.Matches[0].Groups[1].Value }
} catch { }
Say ('page probe rawLen=' + $rawLen + '   (healthy ~2250, blank page was 44)')

if ($tok) {
  try {
    $r = Invoke-WebRequest -Uri ('http://127.0.0.1:' + $Port + '/?token=' + $tok) -UseBasicParsing -TimeoutSec 25
    Say ('GET / -> HTTP ' + $r.StatusCode + ', bytes=' + $r.RawContentLength)
  } catch { Say ('GET / failed: ' + $_.Exception.Message) }
} else { Say 'no fresh token found in the launcher log' }

if ($PatchChecks.Count -eq 0) {
  Say 'client patch checks: none configured (-PatchChecks is empty)'
}
foreach ($pc in $PatchChecks) {
  $pth = [string]$pc.Path
  if (-not $pth -or -not (Test-Path $pth)) { Say ('patch check skipped, file missing: ' + $pth); continue }
  $text = [IO.File]::ReadAllText($pth)
  if ($pc.ContainsKey('MustContain') -and $pc.MustContain) {
    Say (([IO.Path]::GetFileName($pth)) + ' must-contain marker present = ' + $text.Contains([string]$pc.MustContain))
  }
  if ($pc.ContainsKey('MustNotContain') -and $pc.MustNotContain) {
    Say (([IO.Path]::GetFileName($pth)) + ' retired marker back? = ' + $text.Contains([string]$pc.MustNotContain))
  }
}

if ($StampFile) {
  if (Test-Path $StampFile) { Say ('plugin stamp = ' + (Get-Item $StampFile).LastWriteTime) }
  else { Say ('plugin stamp missing: ' + $StampFile) }
} else { Say 'plugin stamp: not configured (-StampFile is empty)' }

Say '=== restart-verify end ==='

if ($SelfTaskName) {
  try {
    Unregister-ScheduledTask -TaskName $SelfTaskName -Confirm:$false -ErrorAction Stop
    Say ('one-shot task unregistered: ' + $SelfTaskName)
  } catch {
    Say ('one-shot task unregister deferred/failed: ' + $_.Exception.Message)
  }
} else { Say 'self-removal skipped (-SelfTaskName is empty)' }
