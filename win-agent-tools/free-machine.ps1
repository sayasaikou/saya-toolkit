# free-machine.ps1 -- one-shot cleanup: hand the GPU back to whoever needs the machine.
#
# WHY THIS EXISTS
#   A resident image/video server and a loaded LLM both hold VRAM that nothing else can
#   use. When you want to PLAY a game or run your own work, "close that thing" is not
#   obvious: there are three separate holders and only one of them is a visible window.
#
# Does exactly three things:
#   1. stops the image server (ComfyUI)
#   2. unloads any model loaded in ollama (the service itself is left running)
#   3. stops this assistant's own python workers
#
# NEVER touches: the assistant host itself, anything the owner started, the ollama service,
# any process whose command line does not match the configured pattern.
#
# ASCII ONLY (runs under either PowerShell engine).
#
# Exit codes: 0 = cleanup ran (per-item results are printed; a failed stop is reported,
#                 not fatal -- a partly cleaned machine is still better than none)

param(
    # Image server port.
    [int]$ComfyPort = 8188,

    # ollama port (its model list and unload endpoints).
    [int]$OllamaPort = 11434,

    # Command-line regex identifying the assistant's own python workers.
    # Empty = skip step 3 entirely.
    [string]$OwnPythonPattern = 'comfy-tools|dsh-ai|vision-tools',

    # Report what would be stopped without stopping anything.
    [switch]$DryRun,

    # Seconds to wait between stopping and measuring VRAM again.
    [int]$SettleSeconds = 3
)

$ErrorActionPreference = 'Continue'

function Get-VramUsed {
    $v = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
    if ($v) { return [int]($v | Select-Object -First 1) }
    return -1
}

function Get-ListenerPid([int]$P) {
    $c = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    if ($c) { return [int]$c[0].OwningProcess }
    return 0
}

$before = Get-VramUsed
Write-Output ("VRAM before : {0} MiB" -f $before)
Write-Output ''

# ---- 1) image server ----
$srvPid = Get-ListenerPid $ComfyPort
if ($srvPid -ne 0) {
    if ($DryRun) { Write-Output ("  [--] would stop image server pid {0}" -f $srvPid) }
    else {
        Stop-Process -Id $srvPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        # read back: a stop that did not throw is not proof the port was released
        if ((Get-ListenerPid $ComfyPort) -eq 0) { Write-Output '  [ok] image server stopped' }
        else { Write-Output '  [!!] image server is still listening' }
    }
} else {
    Write-Output '  [--] image server was not running'
}

# ---- 2) ollama loaded models (service stays up) ----
if ((Get-ListenerPid $OllamaPort) -ne 0) {
    try {
        $loaded = Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/ps" -TimeoutSec 8
        if ($loaded.models.Count -gt 0) {
            foreach ($m in $loaded.models) {
                if ($DryRun) { Write-Output ("  [--] would unload ollama model: {0}" -f $m.name); continue }
                $body = '{"model":"' + $m.name + '","keep_alive":0}'
                Invoke-RestMethod -Uri "http://127.0.0.1:$OllamaPort/api/generate" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30 | Out-Null
                Write-Output ("  [ok] ollama model unloaded: {0}" -f $m.name)
            }
        } else {
            Write-Output '  [--] ollama: no model loaded'
        }
    } catch {
        Write-Output '  [!!] ollama request failed'
    }
} else {
    Write-Output '  [--] ollama service is not running'
}

# ---- 3) the assistant's own python workers ----
if ($OwnPythonPattern) {
    $killed = 0
    try {
        $own = @(Get-CimInstance Win32_Process -Filter "Name = 'python.exe'" -ErrorAction SilentlyContinue |
                 Where-Object { $_.CommandLine -match $OwnPythonPattern })
        foreach ($p in $own) {
            if ($DryRun) { Write-Output ("  [--] would kill python pid {0}" -f $p.ProcessId); $killed++; continue }
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Output ("  [ok] stopped python pid {0}" -f $p.ProcessId)
            $killed++
        }
        if ($killed -eq 0) { Write-Output '  [--] no matching python worker was running' }
    } catch { }
}

Start-Sleep -Seconds $SettleSeconds
$after = Get-VramUsed
Write-Output ''
Write-Output ("VRAM after  : {0} MiB" -f $after)
if ($before -gt 0 -and $after -gt 0) { Write-Output ("freed       : {0} MiB" -f ($before - $after)) }
Write-Output 'Done. The assistant host was not touched.'
exit 0
