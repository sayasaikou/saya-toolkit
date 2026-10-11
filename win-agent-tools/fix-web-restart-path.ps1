# fix-web-restart-path.ps1 -- re-point the dsh-web-restart plugin host at THIS machine's
# restart script.
#
# WHY THIS HAS TO EXIST
#   The plugin host hardcodes the author's own path (D:\1\dsh-web-host.ps1). On any other
#   machine the spawn fails, and it fails SILENTLY: the one-click restart button prints
#   "restart script launched" while nothing restarts. Nothing in the logs says otherwise.
#
# WHY IT HAS TO BE RE-RUN
#   The package is a github: dependency, so any pnpm install / plugin upgrade that re-fetches
#   it restores the author's path and breaks the button again. Run this after every upgrade
#   round. It is idempotent: a second run reports ALREADY PATCHED and changes nothing.
#
# SAFETY
#   Backs up before editing, verifies with `node --check`, and rolls the backup back if the
#   syntax check fails. Only the path fragment is replaced, so the surrounding quotes and
#   escapes in the JS string stay intact.
#
# ASCII ONLY: Task Scheduler / constrained hosts run scripts under Windows PowerShell 5.1,
# which reads a BOM-less UTF-8 file as ANSI and dies on non-ASCII bytes.
#
# Exit codes: 0 = patched or already fine   2 = plugin file missing
#             3 = unexpected content        4 = syntax check failed (rolled back)

param(
    # DSH home folder.
    [string]$DshRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

    # Profile that owns the plugin (the launcher-era profile is 'web').
    [string]$ProfileName = 'web',

    # Node interpreter used for the syntax check. Empty = first node found on PATH.
    [string]$NodeExe = '',

    # Script the button should call instead of the author's path.
    # Empty = <DshRoot>\dsh-restart.ps1, which is the conventional location.
    [string]$RestartScript = '',

    [switch]$Quiet
)

$wr = Join-Path $DshRoot "profiles\$ProfileName\node_modules\dsh-web-restart\lib\index.js"
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$Log = Join-Path $DshRoot 'fix-web-restart-path.log'

if (-not $RestartScript) { $RestartScript = Join-Path $DshRoot 'dsh-restart.ps1' }
if (-not $NodeExe) {
    $NodeExe = (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function W($m) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m
    $line | Out-File -FilePath $Log -Append -Encoding UTF8
    if (-not $Quiet) { Write-Output $line }
}

if (-not (Test-Path -LiteralPath $wr)) { W "SKIP: plugin host file not found: $wr"; exit 2 }

# The path sits inside a JS string literal, so it appears with doubled backslashes.
# Build both the needle and the replacement in that escaped form so only the path
# fragment changes and the surrounding quotes/escapes survive untouched.
$needle = 'D:\\1\\dsh-web-host.ps1'
$repl   = $RestartScript -replace '\\', '\\\\'
$t = Get-Content -LiteralPath $wr -Raw -Encoding UTF8

if ($t.Contains($repl)) { W 'ALREADY PATCHED (no change needed)'; exit 0 }
if (-not $t.Contains($needle)) { W 'UNEXPECTED: neither the author path nor the fixed path was found'; exit 3 }

$bakDir = Join-Path $DshRoot 'backups'
if (-not (Test-Path -LiteralPath $bakDir)) { New-Item -ItemType Directory -Path $bakDir -Force | Out-Null }
$bak = Join-Path $bakDir ('dsh-web-restart.index.js.bak-' + $stamp)
Copy-Item $wr $bak -Force

Set-Content -Path $wr -Value ($t.Replace($needle, $repl)) -Encoding UTF8 -NoNewline

$chk = Get-Content -LiteralPath $wr -Raw -Encoding UTF8
W ('patched: author_path_left=' + $chk.Contains('D:\\1') + ' target_present=' + $chk.Contains([System.IO.Path]::GetFileName($RestartScript)) + ' backup=' + $bak)

if ($NodeExe -and (Test-Path -LiteralPath $NodeExe)) {
    $out = & $NodeExe --check $wr 2>&1
    $rc = $LASTEXITCODE
    W ('node --check exit=' + $rc + ' ' + (($out | Out-String).Trim()))
    if ($rc -ne 0) {
        W 'ROLLBACK: syntax check failed, restoring backup'
        Copy-Item $bak $wr -Force
        exit 4
    }
} else {
    W 'NOTE: no node interpreter found, syntax check skipped -- verify manually before restarting'
}

W 'NOTE: takes effect only after the DSH service restarts (the route closure is registered at startup).'
exit 0
