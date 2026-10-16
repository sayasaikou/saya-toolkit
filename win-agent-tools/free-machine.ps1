# free-machine.ps1 -- one-shot cleanup for when the owner needs the machine (2026-10-10)
#
# Does exactly three things:
#   1. stops ComfyUI
#   2. unloads any model loaded in ollama (service itself is left alone)
#   3. kills this assistant's own python workers
# Never touches: DSH itself, anything the owner started, the ollama service.
# ASCII ONLY (runs under either engine).

$ErrorActionPreference = 'Continue'

function Get-VramUsed {
    $v = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
    if ($v) { return [int]($v | Select-Object -First 1) }
    return -1
}

function Get-ListenerPid([int]$Port) {
    $c = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($c) { return [int]$c[0].OwningProcess }
    return 0
}

$before = Get-VramUsed
Write-Host ("VRAM before : {0} MiB" -f $before)
Write-Host ''

# ---- 1) ComfyUI ----
$comfyProcId = Get-ListenerPid 8188
if ($comfyProcId -ne 0) {
    Stop-Process -Id $comfyProcId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if ((Get-ListenerPid 8188) -eq 0) { Write-Host '  [ok] ComfyUI stopped' }
    else { Write-Host '  [!!] ComfyUI is still listening' }
} else {
    Write-Host '  [--] ComfyUI was not running'
}

# ---- 2) ollama loaded models ----
if ((Get-ListenerPid 11434) -ne 0) {
    try {
        $loaded = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/ps' -TimeoutSec 8
        if ($loaded.models.Count -gt 0) {
            foreach ($m in $loaded.models) {
                $body = '{"model":"' + $m.name + '","keep_alive":0}'
                Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/generate' -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
                Write-Host ("  [ok] ollama model unloaded: {0}" -f $m.name)
            }
        } else {
            Write-Host '  [--] ollama: no model loaded'
        }
    } catch {
        Write-Host '  [!!] ollama request failed'
    }
} else {
    Write-Host '  [--] ollama service is not running'
}

# ---- 3) assistant's own python workers ----
$killed = 0
try {
    $own = @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match 'comfy-tools|dsh-ai|vision-tools' })
    foreach ($p in $own) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Host ("  [ok] killed python pid {0}" -f $p.ProcessId)
        $killed++
    }
    if ($killed -eq 0) { Write-Host '  [--] no assistant python was running' }
} catch { }

Start-Sleep -Seconds 3
$after = Get-VramUsed
Write-Host ''
Write-Host ("VRAM after  : {0} MiB" -f $after)
if ($before -gt 0 -and $after -gt 0) { Write-Host ("freed       : {0} MiB" -f ($before - $after)) }
Write-Host 'Done. DSH itself was not touched.'
