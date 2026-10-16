# reap-producers.ps1 -- idle reaper for production services (policy v1, approved 2026-10-10)
#
# Scope decision: this timer only reaps ComfyUI.
#   ComfyUI  : has /queue, so "busy" is observable -> safe to reap on idle.
#   ollama   : a loaded model is NOT the same as an active request, so a timer
#              cannot tell busy from idle. It is handled by layer L1 (unload
#              right after use) plus ollama's own 5-minute keep_alive expiry.
#   WanGP / Blender : one-shot processes, they exit on their own. Not managed.
#
# Busy => never touch. Idle >= 10 min => stop ComfyUI.
# ASCII ONLY: the scheduled task runs this under Windows PowerShell 5.1, which
# reads BOM-less UTF-8 as ANSI -- non-ASCII text would break parsing silently.

$ErrorActionPreference = 'Continue'
$DshHome     = '$env:DSH_HOME'
$LogPath     = Join-Path $DshHome 'reap-producers.log'
$StatePath   = Join-Path $DshHome 'producer-state.json'
$IdleMinutes = 10

function Write-ReapLog([string]$Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$stamp  $Message" | Add-Content -Path $LogPath -Encoding UTF8
}

function Get-ListenerPid([int]$Port) {
    $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($conn) { return [int]$conn[0].OwningProcess }
    return 0
}

function Read-State {
    $s = @{}
    if (Test-Path $StatePath) {
        try {
            $obj = Get-Content $StatePath -Raw | ConvertFrom-Json
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
$comfyProcId = Get-ListenerPid 8188

if ($comfyProcId -eq 0) {
    # Nothing running. Keep the stamp fresh so the next start gets a full grace period.
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    exit 0
}

# ---- busy checks: any hit means do nothing ----
$busy = $false
$why = ''

try {
    $q = Invoke-RestMethod -Uri 'http://127.0.0.1:8188/queue' -TimeoutSec 8
    if ($q.queue_running.Count -gt 0 -or $q.queue_pending.Count -gt 0) {
        $busy = $true
        $why = 'comfyui queue not empty'
    }
} catch { }

if (-not $busy) {
    try {
        $own = @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match 'comfy-tools|dsh-ai|vision-tools' })
        if ($own.Count -gt 0) {
            $busy = $true
            $why = ('assistant python x{0}' -f $own.Count)
        }
    } catch { }
}

if ($busy) {
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    Write-ReapLog ("busy ({0}) -> kept ComfyUI pid {1}" -f $why, $comfyProcId)
    exit 0
}

$last = $null
if ($state.ContainsKey('comfyui_last_busy')) {
    try { $last = [datetime]::Parse($state['comfyui_last_busy']) } catch { $last = $null }
}
if (-not $last) {
    $state['comfyui_last_busy'] = $now.ToString('o')
    Save-State $state
    exit 0
}

$idle = ($now - $last).TotalMinutes
if ($idle -lt $IdleMinutes) { exit 0 }

Stop-Process -Id $comfyProcId -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

if ((Get-ListenerPid 8188) -eq 0) {
    Write-ReapLog ("idle {0:N1} min -> stopped ComfyUI pid {1}" -f $idle, $comfyProcId)
    $state['comfyui_last_busy'] = (Get-Date).ToString('o')
    Save-State $state
} else {
    Write-ReapLog ("idle {0:N1} min -> FAILED to stop ComfyUI pid {1}" -f $idle, $comfyProcId)
}
exit 0
