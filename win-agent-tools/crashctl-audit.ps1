# crashctl-audit.ps1 -- find out WHO keeps rewriting the crash-dump registry values.
#
# THE PROBLEM THIS SOLVES
#   CrashDumpEnabled and MinidumpDir under
#   HKLM\SYSTEM\CurrentControlSet\Control\CrashControl kept being reverted by something
#   outside this machine's control (a self-healing guard script had to put them back 34
#   times over four days). Nothing in the event log named the writer. This script answers
#   "which process did it" by making the key auditable and then reading the resulting
#   object-access events.
#
# WHAT IT CHANGES (read this before running -Install)
#   * adds a SetValue audit ACE on that one registry key
#   * enables the Object Access / Registry audit subcategory
#   Both are RECORDED BEFORE they are changed (audit policy + SACL are written to disk),
#   and -Uninstall puts them back. Auditing a single key is what makes the writer visible;
#   without it the event simply is not generated.
#
# MODES
#   -Install    record prior state, enable auditing, add the audit ACE
#   -Status     show current audit policy + ACE + Security log health
#   -Uninstall  remove the ACE and turn the subcategory back off
#   -Catch      dump recent events for this key (the guard calls this on every revert)
#
# REQUIRES ELEVATION. ASCII only: also runs under PS 5.1 via a scheduled task.

param(
  # DSH home folder. Holds the log and the recorded prior state.
  [string]$DshRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  [switch]$Install,
  [switch]$Status,
  [switch]$Uninstall,
  [switch]$Catch,

  # -Catch: how far back to look, in minutes.
  [int]$Minutes = 35
)
$ErrorActionPreference = 'Continue'

$keyName = 'SYSTEM\CurrentControlSet\Control\CrashControl'
$subGuid = '{0CCE921E-69AE-11D9-BED3-505054503030}'   # Object Access / Registry
$log     = Join-Path $DshRoot 'crashctl-audit.log'
$bkDir   = Join-Path $DshRoot 'backups\crashctl-audit'

function W([string]$t) {
  $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $t
  Add-Content -LiteralPath $log -Value $line -Encoding UTF8
  # keep the log bounded: 512 KB, then trim to the last 500 lines
  if ((Get-Item -LiteralPath $log).Length -gt 524288) {
    $tail = Get-Content -LiteralPath $log -Tail 500
    Set-Content -LiteralPath $log -Value $tail -Encoding UTF8
  }
  Write-Output $line
}

function Get-AuditKey {
  $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        $keyName,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::ChangePermissions)
  if ($null -eq $k) { throw 'cannot open key with ChangePermissions (run elevated?)' }
  return $k
}

function Get-PolicyLine {
  # auditpol output is LOCALIZED, so this must not match on an English header word.
  # It keeps every non-empty line that is not a rule of dashes and takes the LAST one:
  # auditpol prints its table first and the single result line at the end, so the last
  # line is the value in any language (taking the FIRST would return the header).
  $out = (& auditpol /get /subcategory:"$subGuid" 2>&1 | Out-String)
  $lines = @($out -split "`r?`n" | Where-Object { $_.Trim() -ne '' -and $_ -notmatch '^\s*-{2,}\s*$' })
  if ($lines.Count -eq 0) { return 'unknown' }
  return $lines[-1].Trim()
}

function Get-SaclSddl {
  $k = Get-AuditKey
  try {
    $sec = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Audit)
    return $sec.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Audit)
  } finally { $k.Close() }
}

if ($Install) {
  New-Item -ItemType Directory -Path $bkDir -Force | Out-Null
  $f1 = Join-Path $bkDir 'before-auditpol.txt'
  $f2 = Join-Path $bkDir 'before-sacl.txt'
  if (-not (Test-Path $f1)) {
    [IO.File]::WriteAllText($f1, (Get-PolicyLine), (New-Object Text.UTF8Encoding($false)))
    W ('saved prior audit policy -> ' + $f1)
  } else { W 'prior audit policy already recorded (kept)' }
  if (-not (Test-Path $f2)) {
    [IO.File]::WriteAllText($f2, (Get-SaclSddl), (New-Object Text.UTF8Encoding($false)))
    W ('saved prior SACL -> ' + $f2)
  } else { W 'prior SACL already recorded (kept)' }

  $k = Get-AuditKey
  try {
    $sec = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Audit)
    $rule = New-Object System.Security.AccessControl.RegistryAuditRule(
      'Everyone',
      [System.Security.AccessControl.RegistryRights]::SetValue,
      [System.Security.AccessControl.InheritanceFlags]::None,
      [System.Security.AccessControl.PropagationFlags]::None,
      [System.Security.AccessControl.AuditFlags]::Success)
    $sec.AddAuditRule($rule)
    $k.SetAccessControl($sec)
  } finally { $k.Close() }

  & auditpol /set /subcategory:"$subGuid" /success:enable | Out-Null

  W ('audit policy now : ' + (Get-PolicyLine))
  W ('SACL now         : ' + (Get-SaclSddl))
  W 'INSTALL DONE (rollback: crashctl-audit.ps1 -Uninstall)'
  exit 0
}

if ($Status) {
  W ('audit policy : ' + (Get-PolicyLine))
  W ('SACL         : ' + (Get-SaclSddl))
  # A Security log that rolls over faster than the revert interval would hide the events,
  # so report its size and how far back it actually reaches before trusting a "no hits".
  $sec = Get-WinEvent -ListLog Security
  W ('Security log : ' + [math]::Round($sec.MaximumSizeInBytes / 1MB, 0) + ' MB, mode=' + $sec.LogMode + ', records=' + $sec.RecordCount)
  $oldest = Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction SilentlyContinue
  if ($oldest) { W ('oldest event : ' + $oldest.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')) }
  exit 0
}

if ($Uninstall) {
  $k = Get-AuditKey
  try {
    $sec = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Audit)
    foreach ($r in @($sec.GetAuditRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
      [void]$sec.RemoveAuditRuleSpecific($r)
    }
    $k.SetAccessControl($sec)
  } finally { $k.Close() }
  & auditpol /set /subcategory:"$subGuid" /success:disable | Out-Null
  W ('audit policy now : ' + (Get-PolicyLine))
  W ('SACL now         : ' + (Get-SaclSddl))
  W 'UNINSTALL DONE'
  exit 0
}

if ($Catch) {
  # MEASURED TRAP: a SetValue on this key shows up as Security 4663 (object access,
  # ObjectType=Key), not 4657 as the event name suggests. Its ObjectName is reported with
  # the ControlSet001 spelling, not CurrentControlSet -- so match on 'Control\CrashControl'
  # and you catch both spellings. Matching on the CurrentControlSet form finds nothing.
  $start = (Get-Date).AddMinutes(-1 * $Minutes)
  $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = @(4657, 4663); StartTime = $start } -ErrorAction SilentlyContinue)
  W ('CATCH: window last ' + $Minutes + ' min, raw events = ' + $ev.Count)
  $hits = 0
  foreach ($e in $ev) {
    $x = [xml]$e.ToXml()
    $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = [string]$n.'#text' }
    if ($d['ObjectName'] -notlike '*Control\CrashControl*') { continue }
    $hits++
    W ('  HIT id=' + $e.Id + ' ' + $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss') + '  value=' + $d['ObjectValueName'] + '  proc=' + $d['ProcessName'] + '  pid=' + $d['ProcessId'] + '  op=' + $d['OperationType'] + '  acl=' + ($d['AccessList'] -replace '\s+', ' '))
  }
  W ('CATCH: hits on this key = ' + $hits)
  exit 0
}

Write-Output 'usage: crashctl-audit.ps1 -Install | -Status | -Uninstall | -Catch [-Minutes N]'
