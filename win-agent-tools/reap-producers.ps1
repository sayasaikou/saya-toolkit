# reap-producers.ps1 -- idle reaper for local model servers.
#
# WHY A REAPER AT ALL
#   A model server that stays resident holds VRAM that nothing else can use, and the next
#   job then fails or spills to system RAM. Stopping it on idle is what keeps the machine
#   usable between runs. The hard part is telling "idle" from "busy" -- see the scope rule
#   below, which is the reason this only manages one kind of server.
#
# SCOPE RULE -- only reap a server that can actually be asked whether it is busy
#   ComfyUI          : has /queue, so "busy" is observable -> safe to reap on idle.
#   ollama           : a LOADED MODEL is not the same as an ACTIVE REQUEST, so a timer
#                      cannot tell busy from idle. Handled by unloading right after use
#                      plus the server's own keep_alive expiry instead.
#   WanGP / Blender  : one-shot processes, they exit on their own. Not managed here.
#   Anything else    : add it only if it exposes an equivalent busy signal.
#
# RULE: busy => never touch. Idle for $IdleMinutes => stop the server.
#
# ASCII ONLY: a scheduled task runs this under Windows PowerShell 5.1, which reads a
# BOM-less UTF-8 file as ANSI -- non-ASCII text would break parsing silently.
#
# Exit codes: 0 = always (this is a timer job; it reports through the log)

param(
    # Folder holding the log and the idle-state file.
    [string]$DshRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

    # Port the managed server listens on (its HTTP API and its queue endpoint).
    [int]$Port = 8188,

    # Minutes of continuous idle before the server is stopped.
    [int]$IdleMinutes = 10,

    # Extra safety net: command-line patterns that mean "the assistant itself is working".
    # Any matching python.exe counts as busy even when the server queue looks empty.
    # Regex, matched against the full command line. Empty = skip this check entirely.
    [string]$BusyCmdlinePattern = 'comfy-tools|dsh-ai|vision-tools',

    # Report only; never stop anything.
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$LogPath   = Join-Path $DshRoot 'reap-producers.log'
$StatePath = Join-Path $DshRoot 'producer-state.json'

function Write-ReapLog([string]$Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp  $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

function Get-ListenerPid([int]$P) {
    $conn = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return [int]$conn[0].OwningProcess }
    return 0
}

function Read-State {
    $s = @{}
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $obj = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $s[$p.Name] = [string]$p.Value }
        } catch { }
    }
    return $s
}

function Save-State($s) {
    try { ($s | ConvertTo-Json -Compress) | Set-Content -Path $StatePath -Encoding UTF8 } catch { }
}

$state = Read-State
$now = Get-Date
$srvProcId = Get-ListenerPid $Port

if ($srvProcId -eq 0) {
    # Nothing running. Keep the stamp fresh so the next start gets a full grace period.
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    exit 0
}

# ---- busy checks: any hit means do nothing ----
$busy = $false
$why = ''

try {
    $q = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/queue" -TimeoutSec 8
    if ($q.queue_running.Count -gt 0 -or $q.queue_pending.Count -gt 0) {
        $busy = $true
        $why = 'server queue not empty'
    }
} catch { }

if (-not $busy -and $BusyCmdlinePattern) {
    try {
        $own = @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match $BusyCmdlinePattern })
        if ($own.Count -gt 0) {
            $busy = $true
            $why = ('assistant python x{0}' -f $own.Count)
        }
    } catch { }
}

if ($busy) {
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    if ($DryRun) { Write-Output "busy ($why) -> would keep pid $srvProcId" }
    else { Write-ReapLog ("busy ({0}) -> kept server pid {1}" -f $why, $srvProcId) }
    exit 0
}

$last = $null
if ($state.ContainsKey('comfyui_last_busy')) {
    try { $last = [datetime]::Parse($state['comfyui_last_busy']) } catch { $last = $null }
}
if (-not $last) {
    # No usable stamp: treat this run as the start of the grace period rather than
    # stopping a server whose idle time is unknown.
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    exit 0
}

$idle = ($now - $last).TotalMinutes
if ($idle -lt $IdleMinutes) { exit 0 }

if ($DryRun) {
    Write-Output ("idle {0:N1} min -> would stop server pid {1}" -f $idle, $srvProcId)
    exit 0
}

Stop-Process -Id $srvProcId -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# Always verify afterwards: "Stop-Process did not throw" is not proof the port is free.
if ((Get-ListenerPid $Port) -eq 0) {
    Write-ReapLog ("idle {0:N1} min -> stopped server pid {1}" -f $idle, $srvProcId)
    $state['comfyui_last_busy'] = (Get-Date).ToString('o')
    Save-State $state
} else {
    Write-ReapLog ("idle {0:N1} min -> FAILED to stop server pid {1}" -f $idle, $srvProcId)
}
Write-Output ("reap: idle {0:N1} min" -f $idle)
exit 0
