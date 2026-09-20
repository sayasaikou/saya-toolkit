# fix-flash-tasks.ps1 -- stop scheduled tasks from flashing a console window.
#
# WHY: a task action that runs powershell.exe (or cmd.exe) directly allocates a console
# window for a moment, and -WindowStyle Hidden still shows one briefly. Replacing the
# action with
#
#     wscript.exe "<DshHome>\run-hidden-task.vbs" <id>
#
# removes the window entirely: WScript.Shell.Run(cmd, 0, False) never allocates a console,
# so there is nothing to flash and nothing for a user to close by accident. A visible
# window is not only ugly -- a task whose window gets closed mid-run is killed with it.
#
# It also slows one high-frequency task down to every 6 hours (its data changes slowly).
#
# ROLLBACK: every task definition is exported before it is touched, to
#   <DshHome>\backups\task-xml-<stamp>\<TaskName>.xml
# and can be restored (elevated shell required) with:
#   Register-ScheduledTask -Xml (Get-Content <file> -Raw) -TaskName <name> -Force
#
# ASCII ONLY -- Task Scheduler runs this under Windows PowerShell 5.1, which reads a
# BOM-less UTF-8 file as ANSI and dies on non-ASCII bytes.
#
# PREREQUISITES
#   * run-hidden-task.vbs exists in the DSH home. It is the windowless launcher: the task
#     id is passed as its first argument and selects which script it starts.
#   * The task names in $TaskMap exist; unknown ones are reported as SKIP, never created.
#   * Changing a task needs an elevated shell, and 'no error returned' is NOT proof:
#     always read back State + NextRunTime + the action string (this script does).
[CmdletBinding()]
param(
  # Folder that holds the DSH tools and the windowless launcher.
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Windowless launcher (a VBScript shim) that receives the task id as argument 1.
  # Empty = <DshHome>\run-hidden-task.vbs
  [string]$HiddenRunner = '',

  # Task name -> runner id. Empty = the built-in example map set below.
  # Pass your own, e.g. -TaskMap @{ Name = 'MY_Task'; Id = 'mytask' }
  [hashtable[]]$TaskMap = @(),

  # The one high-frequency task whose repetition interval also gets rewritten.
  [string]$SlowTaskName = 'DSH_HandoffCheck',

  # New repetition interval in hours for $SlowTaskName. 0 = leave triggers alone.
  [int]$SlowTaskHours = 6
)

$LogPath = Join-Path $DshHome 'fix-flash-tasks.log'
function W([string]$m) {
  Add-Content -Path $LogPath -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) -Encoding UTF8
}

$Vbs = $HiddenRunner
if (-not $Vbs) { $Vbs = Join-Path $DshHome 'run-hidden-task.vbs' }
$stamp     = Get-Date -Format 'yyyyMMdd-HHmm'
$backupDir = Join-Path $DshHome ('backups\task-xml-' + $stamp)
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

if (-not $TaskMap -or $TaskMap.Count -eq 0) {
  $TaskMap = @(
    @{ Name = 'DSH_Watchdog';         Id = 'watchdog' },
    @{ Name = 'DSH_HandoffCheck';     Id = 'handoff'  },
    @{ Name = 'DSH_SnapshotDaily';    Id = 'snapshot' },
    @{ Name = 'DSH_WindowStateGuard'; Id = 'winguard' }
  )
}

W '=========== fix flash tasks start ==========='
if (-not (Test-Path $Vbs)) { W ('ABORT: hidden runner not found: ' + $Vbs); exit 2 }
W ('runner = ' + $Vbs)
W ('xml backup dir = ' + $backupDir)

foreach ($item in $TaskMap) {
  $taskName = [string]$item.Name
  $taskId   = [string]$item.Id
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if (-not $t) { W ('SKIP (not found): ' + $taskName); continue }

  try {
    Export-ScheduledTask -TaskName $taskName | Out-File -FilePath (Join-Path $backupDir ($taskName + '.xml')) -Encoding UTF8
    W ('backup xml ok: ' + $taskName)
  } catch { W ('backup xml FAILED ' + $taskName + ': ' + $_.Exception.Message) }

  $oldAct = ($t.Actions | ForEach-Object { ($_.Execute + ' ' + $_.Arguments).Trim() }) -join ' ; '
  # TECH NOTE: quote the script path and pass the id as a separate argument. Task actions
  # store a plain string, so an unquoted path with spaces silently splits into two tokens.
  $newAct = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $Vbs + '" ' + $taskId)

  if ($SlowTaskHours -gt 0 -and $taskName -eq $SlowTaskName) {
    # TECH NOTE: never pass [TimeSpan]::MaxValue as -RepetitionDuration. It serializes to
    # P99999999DT... and task registration fails outright. A long finite span works.
    $trg = New-ScheduledTaskTrigger -Once -At ((Get-Date).Date.AddMinutes(10)) -RepetitionInterval (New-TimeSpan -Hours $SlowTaskHours) -RepetitionDuration (New-TimeSpan -Days 3650)
    try {
      Set-ScheduledTask -TaskName $taskName -Action $newAct -Trigger $trg | Out-Null
      W ('UPDATED (action + ' + $SlowTaskHours + 'h trigger): ' + $taskName)
    } catch { W ('UPDATE FAILED ' + $taskName + ': ' + $_.Exception.Message) }
  } else {
    try {
      Set-ScheduledTask -TaskName $taskName -Action $newAct | Out-Null
      W ('UPDATED (action): ' + $taskName)
    } catch { W ('UPDATE FAILED ' + $taskName + ': ' + $_.Exception.Message) }
  }
  W ('   old: ' + $oldAct)
  W ('   new: wscript.exe "' + $Vbs + '" ' + $taskId)
}

W '--- read back ---'
foreach ($item in $TaskMap) {
  $taskName = [string]$item.Name
  $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
  if ($t) {
    $a = ($t.Actions | ForEach-Object { ($_.Execute + ' ' + $_.Arguments).Trim() }) -join ' ; '
    $tr = ($t.Triggers | ForEach-Object { $c = ($_.CimClass.CimClassName -replace 'MSFT_Task',''); $iv = $_.Repetition.Interval; if ($iv) { $c + '(' + $iv + ')' } else { $c } }) -join ','
    $info = $t | Get-ScheduledTaskInfo
    W ($taskName + ' | state=' + $t.State + ' | runLevel=' + $t.Principal.RunLevel + ' | trig=' + $tr + ' | next=' + $info.NextRunTime + ' | act=' + $a)
  } else { W ('MISSING after update: ' + $taskName) }
}
W '=========== fix flash tasks end ==========='
