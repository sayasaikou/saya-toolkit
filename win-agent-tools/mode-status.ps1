# mode-status.ps1 -- one line telling you which power profile is currently applied.
#
# WHY: the three profile scripts (mode-turbo / mode-silent / mode-restore) each set nine
# processor settings. When something else (a vendor tuning utility, a Windows update)
# rewrites a subset of them, the machine ends up in a state that is none of the three and
# nothing reports it. This script reads the nine values back and names the profile, so a
# mixed state is visible instead of being discovered later as "why is it loud again".
#
# It only reads. Run it after any profile switch, or whenever behaviour looks off.
#
# ASCII ONLY: this runs under Windows PowerShell 5.1 in some deployments, which reads a
# BOM-less UTF-8 file as ANSI and dies on non-ASCII bytes.
#
# Exit codes: 0 = reported (including the mixed state, which is a finding, not an error)

param(
    # DSH home folder. Holds power-settings-backup.json (the MSI stock values).
    [string]$DshRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

    # Report the battery (DC) values instead of the plugged-in (AC) ones.
    [switch]$Dc
)

$keys = @('PROCTHROTTLEMAX', 'PROCTHROTTLEMIN', 'PERFEPP', 'PERFBOOSTMODE', 'SYSCOOLPOL',
          'CPMINCORES', 'PERFINCTHRESHOLD', 'PERFDECTHRESHOLD', 'LATENCYHINTPERF')

# The field labels in `powercfg /query` output are LOCALIZED, so this must not match on
# them. The VALUE ORDER is stable in every language instead, and this is the trap worth
# knowing about: one key prints FIVE 0x values before the two that matter
#
#     最小可能的设置: 0x00000000      min possible
#     最大可能的设置: 0x00000064      max possible
#     可能的设置增量: 0x00000001      increment
#     当前交流电源设置索引: 0x00000064   <- AC, what the profile scripts set
#     当前直流电源设置索引: 0x00000064   <- DC (battery)
#
# Taking the FIRST 0x (the obvious thing to do) always yields the minimum, i.e. a
# fingerprint of 0,0,0,... that matches nothing. Take the second-to-last and last instead,
# which is position-stable and therefore language-independent.
$vals = @()
foreach ($k in $keys) {
    $raw = powercfg /query SCHEME_CURRENT SUB_PROCESSOR $k 2>&1 | Out-String
    $hex = @([regex]::Matches($raw, '0x[0-9a-fA-F]+') | ForEach-Object { $_.Value })
    $v = -1
    if ($hex.Count -ge 2) {
        $pick = $hex.Count - 2
        if ($Dc) { $pick = $hex.Count - 1 }
        $v = [Convert]::ToInt32($hex[$pick].Substring(2), 16)
    }
    $vals += $v
}
$cur = $vals -join ','

$bakPath = Join-Path $DshRoot 'power-settings-backup.json'
$restore = ''
if (Test-Path -LiteralPath $bakPath) {
    try {
        $bak = Get-Content -LiteralPath $bakPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $restore = (($bak.values.PSObject.Properties | ForEach-Object { $_.Value.AC }) -join ',')
    } catch { $restore = '' }
}

# Fingerprints of the two profiles, in the same key order as $keys above.
$turbo  = '100,100,0,2,1,100,0,0,100'
$silent = '100,5,80,0,0,5,60,40,0'

$name = 'unknown (mixed state)'
if ($cur -eq $turbo) { $name = 'turbo' }
elseif ($cur -eq $silent) { $name = 'silent' }
elseif ($restore -and $cur -eq $restore) { $name = 'vendor stock (no profile applied)' }

Write-Output ''
Write-Output ("  power profile : {0}" -f $name)
Write-Output ("  fingerprint   : {0}" -f $cur)
if ($name -like 'unknown*') {
    Write-Output '  [!] matches none of the three known states -- a vendor utility may have'
    Write-Output '      rewritten part of them; re-running mode-turbo.ps1 / mode-silent.ps1 fixes it.'
}
Write-Output ''
exit 0
