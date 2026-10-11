param(
    [switch]$Check,
    [switch]$Register,
    [switch]$LogOnly,
    [string]$LogPath = '',
    [string]$DshRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),
    [string]$Workspace = $(if ($env:DSH_WORKSPACE) { $env:DSH_WORKSPACE } else { Join-Path $env:USERPROFILE 'workspace' }),
    [string]$ProfileName = '',

    # Patch-block id of the skin whose on/off flag is reported. Empty = skip the skin
    # section entirely (a machine that uses no skins should not need to configure this).
    [string]$SkinId = '',

    # Declare that "the skin is off in every layer" is the intended state, not drift.
    # Use this when the skin is deliberately kept off (for example because it conflicts
    # with another UI plugin). Without it, an all-off skin is still reported -- as
    # "off (uniform)" rather than as a warning -- so the state stays visible either way.
    [switch]$SkinExpectedOff
)

# ---------------------------------------------------------------------------
# WHAT TO WATCH - edit these two for your own deployment.
#
#   $MonitoredTasks : scheduled task names this script reports on (every run).
#                     Read yours with:  Get-ScheduledTask | Select TaskName
#                     Empty list = skip the whole task section.
#
#   $PersonaPlugin  : OPTIONAL. Name of a plugin directory under
#                     "<DshRoot>\profiles\<ProfileName>\plugins\" whose own check
#                     script self-verifies an injected prompt/persona (for example,
#                     a plugin that injects a character spec on session start).
#                     If the directory is absent the check is reported as
#                     "n/a" - never a warning. Set to '' to disable.
# ---------------------------------------------------------------------------
$script:MonitoredTasks = @()  # e.g. @('MyBackupTask','MyWatchdog')
$script:PersonaPlugin  = ''  # e.g. 'my-persona-plugin'
$script:BootExpect     = @()  # e.g. @('my-plugin/client.js')
$script:MemeGlob       = ''   # e.g. 'my-memes\*'
$script:BootSource     = 'disk'  # 'disk' | 'http' | 'auto' - see Get-BootFact

# Which directory under "<DshRoot>\profiles\" is the live profile: it locates the
# skin patch layers, the optional persona plugin and the on-disk boot inventory.
# Empty -ProfileName = auto-detect, preferring 'desktop' (the official Electron
# client owns that name), then 'web' (the launcher era).
if ([string]::IsNullOrEmpty($ProfileName)) {
    $script:ProfileName = ''
    foreach ($cand in @('desktop', 'web')) {
        if (Test-Path -LiteralPath (Join-Path $DshRoot "profiles\$cand")) { $script:ProfileName = $cand; break }
    }
} else {
    $script:ProfileName = $ProfileName
}
$script:ProfileRoot = Join-Path $DshRoot 'profiles'
if (-not [string]::IsNullOrEmpty($script:ProfileName)) { $script:ProfileRoot = Join-Path $script:ProfileRoot $script:ProfileName }

# ---------------------------------------------------------------------------
# HANDOFF drift check / renderer.
#
# Pure ASCII on purpose: Scheduled Tasks run this through Windows PowerShell 5.1,
# which reads a BOM-less UTF-8 file as ANSI. Any Chinese text in THIS file would
# turn into mojibake and break parsing (that exact bug shipped once, exit code 1,
# no log written). All Chinese display text lives in handoff-template.md instead.
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'
$script:Warn = New-Object System.Collections.Generic.List[string]
$script:Log = New-Object System.Collections.Generic.List[string]
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:NodeExe = 'node'
$script:SpecChars = $null
$script:StateTxt = $null
$script:MarkersFatal = $false
if ([string]::IsNullOrEmpty($LogPath)) { $LogPath = "${DshRoot}\handoff\handoff-check.log" }

function Say { param([string]$s) if (-not $LogOnly) { Write-Output $s }; if ($script:Log.Count -lt 5000) { $script:Log.Add([string]$s) | Out-Null } }
function NewWarn { param([string]$s) $script:Warn.Add($s) | Out-Null }
function Format-Bytes { param([int]$n) if ($n -ge 1024) { return ("{0:n1} KB" -f ($n / 1024)) } return "$n B" }
function Clean-Cell { param([string]$s) return ($s -replace '\*\*', '' -replace '`', '').Trim() }

# read UTF-8 no matter whether the file carries a BOM
function Read-TextSafe {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
        return $t
    } catch { return $null }
}

function Get-AgeHours { param($Stamp) if ($null -eq $Stamp) { return $null } return [math]::Round((New-TimeSpan -Start $Stamp -End (Get-Date)).TotalHours, 1) }

# power of two (1,2,4,8,...) used by the template's {{#ID}} region markers
function Test-IdBit { param([int]$Mask, [int]$Bit) return (($Mask -band $Bit) -eq $Bit) }

# ---------------------------------------------------------------- collectors

function Get-FileFact {
    param([string]$Path, [string]$Label)
    $i = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $i) { NewWarn "missing file: $Label -> $Path"; return $null }
    return [ordered]@{ label = $Label; path = $Path; mtime = $i.LastWriteTime; size = $i.Length; age = (Get-AgeHours $i.LastWriteTime) }
}

function Get-SkinFact {
    $rows = @()
    foreach ($f in @("${DshRoot}\cordis.patch.yml", "$script:ProfileRoot\cordis.patch.yml")) {
        $txt = Read-TextSafe $f
        # A missing patch file on a machine that does not use skins is normal:
        # skip silently instead of warning (the default has no patch files).
        if ($null -eq $txt) { continue }
        $lines = $txt -split "`r?`n"
        $flag = $null; $label = 'no-flag'
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('id:\s*' + [regex]::Escape($SkinId))) {
                for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $lines.Count); $j++) {
                    if ($lines[$j] -match 'disabled:\s*(true|false)') { $flag = ($Matches[1] -eq 'false'); $label = $Matches[1]; break }
                }
                break
            }
        }
        $rows += [pscustomobject]@{ file = (Split-Path $f -Leaf); dir = (Split-Path (Split-Path $f -Parent) -Leaf); enabled = $flag; label = $label; note = '?' }
    }

    # WHY "ALL OFF" IS NOT AUTOMATICALLY A PROBLEM
    # A skin manager writes disabled: true into every layer on its own, and a skin the owner
    # turned off by hand is a legitimate state, not drift. Treating it as drift produces a
    # probe that is red forever on machines where the skin is simply not in use -- and a
    # permanently red probe gets ignored exactly when it matters.
    # What IS worth a warning is an INCONSISTENT state: one layer on, another off. That means
    # something wrote to one of them without the other, which is the real failure signature.
    $offRows = @($rows | Where-Object { $_.enabled -eq $false })
    $onRows = @($rows | Where-Object { $_.enabled -eq $true })
    $note = 'off (CHECK: not uniform)'
    if ($rows.Count -gt 0 -and $onRows.Count -eq $rows.Count) { $note = 'on' }
    if ($rows.Count -gt 0 -and $offRows.Count -eq $rows.Count) { $note = 'off (uniform)' }
    if ($SkinExpectedOff -and $rows.Count -gt 0 -and $offRows.Count -eq $rows.Count) { $note = 'off (declared expected by -SkinExpectedOff)' }
    foreach ($r in $rows) { $r.note = $note }

    $inconsistent = @($rows | Where-Object { $_.enabled -ne $true -and $_.enabled -ne $false })
    if ($inconsistent.Count -gt 0) {
        NewWarn ("skin flag unreadable (no disabled: entry found): " + (($inconsistent | ForEach-Object { "$($_.dir)/$($_.file)" }) -join ', '))
    } elseif ($offRows.Count -gt 0 -and $onRows.Count -gt 0) {
        NewWarn ("skin flag not uniform across layers (one on, one off -- the manager may have rewritten only one): " + (($rows | ForEach-Object { "$($_.dir)/$($_.file)=$($_.label)" }) -join ', '))
    }
    return $rows
}

function Get-TaskFact {
    param([string[]]$Names)
    $rows = @()
    foreach ($n in $Names) {
        # literal path on purpose: under Task Scheduler the %SystemRoot% based path did not
        # resolve and every query came back empty ("task missing" x3), a false alarm.
        $raw = & 'C:\Windows\System32\schtasks.exe' /query /tn $n /fo LIST /v 2>&1 | Out-String
        # field labels are LOCALIZED (Chinese on this box) -> match on the task name and map keys
        if ($raw -notmatch [regex]::Escape($n)) { $rows += [pscustomobject]@{ name = $n; exists = $false; state = ''; next = ''; last = '' }; NewWarn "scheduled task missing: $n"; continue }
        $aliases = @{
            'Status'        = @('Status', [char]0x72B6 + [char]0x6001)
            'Next Run Time' = @('Next Run Time', [char]0x4E0B + [char]0x6B21 + [char]0x8FD0 + [char]0x884C + [char]0x65F6 + [char]0x95F4)
            'Last Run Time' = @('Last Run Time', [char]0x4E0A + [char]0x6B21 + [char]0x8FD0 + [char]0x884C + [char]0x65F6 + [char]0x95F4)
        }
        $props = @{}
        foreach ($line in ($raw -split "`r?`n")) {
            if ($line -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
                if (-not $props.ContainsKey($k)) { $props[$k] = $v }
            }
        }
        $stateVal = ''; $nextVal = ''; $lastVal = ''
        foreach ($k in $aliases['Status']) { if ($stateVal -eq '' -and $props.ContainsKey($k)) { $stateVal = $props[$k] } }
        foreach ($k in $aliases['Next Run Time']) { if ($nextVal -eq '' -and $props.ContainsKey($k)) { $nextVal = $props[$k] } }
        foreach ($k in $aliases['Last Run Time']) { if ($lastVal -eq '' -and $props.ContainsKey($k)) { $lastVal = $props[$k] } }
        $rows += [pscustomobject]@{ name = $n; exists = $true; state = $stateVal; next = $nextVal; last = $lastVal }
    }
    return $rows
}

function Get-MemeFact {
    $dir = if ($script:MemeGlob) { Join-Path $DshRoot $script:MemeGlob } else { '' }
    # Not configured (or not present) is a silent "n/a", not a warning: the meme
    # library is a deployment extra, not part of the handoff contract.
    if ([string]::IsNullOrEmpty($dir)) { return $null }
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $files = Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction SilentlyContinue
    return [ordered]@{
        total     = $files.Count
        official  = @($files | Where-Object { $_.FullName -match 'official-' }).Count
        custom    = @($files | Where-Object { $_.Name -notmatch '^official-' }).Count
    }
}

function Get-NodeFact {  # resolves the node interpreter used for JS-side checks
    $found = $null
    foreach ($p in @($script:NodeExe, 'C:\Program Files\nodejs\node.exe', 'C:\Program Files (x86)\nodejs\node.exe') + (Get-Command node -ErrorAction SilentlyContinue | ForEach-Object { $_.Source })) {
        if (Test-Path -LiteralPath $p) {
            $v = $null
            try { $v = (& $p --version 2>&1 | Out-String).Trim() } catch { $v = 'unrunnable' }
            $found = [pscustomobject]@{ path = $p; version = $v }
            break
        }
    }
    if ($null -eq $found) { NewWarn "no node interpreter found (tried $script:NodeExe)"; return $null }
    # Node resolved from PATH or a standard install dir; nothing further to note.
    return $found
}

function Get-BootFact {
    # Where the "which client bundles actually came up" list comes from. Both
    # sources answer the same question, they just use different evidence:
    #
    #   disk (default) : inventory the bundles named in the active profile's
    #                    package.json that really ship a client.js on disk. No
    #                    HTTP, no token, no running service. This is the only
    #                    workable source for the official Electron desktop client:
    #                    it keeps its per-boot web token inside the app, so
    #                    scraping the index page from outside is rejected and the
    #                    old check silently lost its source.
    #   http           : the legacy dsh-launcher shape - read the web token out of
    #                    the launcher log, fetch the index page and take the
    #                    client.js list from the HTML.
    #   auto           : disk when the profile package.json exists, else http.
    #
    # A source that is not there is only worth a warning when $script:BootExpect
    # actually asks for something; an unconfigured check just says "unavailable".
    param([string[]]$Expect)
    if ($null -eq $Expect) { $Expect = @() }
    $source = [string]$script:BootSource
    if ($source -ne 'disk' -and $source -ne 'http') { $source = 'auto' }
    $profilePj = Join-Path $script:ProfileRoot 'package.json'
    $launcherLog = "${DshRoot}\dsh-launcher\dsh.log"
    if ($source -eq 'auto') { if (Test-Path -LiteralPath $profilePj) { $source = 'disk' } else { $source = 'http' } }
    if ($source -eq 'disk' -and -not (Test-Path -LiteralPath $profilePj)) {
        if (@($Expect).Count -gt 0) { NewWarn "boot manifest source unavailable: no profile package.json at $profilePj (set `$script:BootSource = 'http' for the launcher shape)" }
        return $null
    }
    if ($source -eq 'http' -and -not (Test-Path -LiteralPath $launcherLog)) {
        if (@($Expect).Count -gt 0) { NewWarn "boot manifest source unavailable: no launcher log at $launcherLog" }
        return $null
    }
    if ($source -eq 'http') { return Get-BootFactHttp -Expect $Expect -LogFile $launcherLog }
    return Get-BootFactDisk -Expect $Expect
}

function Get-BootFactDisk {
    param([string[]]$Expect)
    $profileRoot = $script:ProfileRoot
    $profilePj = Join-Path $profileRoot 'package.json'
    $bundles = @()
    try { $bundles = @((Get-Content -LiteralPath $profilePj -Raw -Encoding UTF8 | ConvertFrom-Json).dsh.profile.bundles) }
    catch { NewWarn ('profile package.json unreadable: ' + $_.Exception.Message); return $null }
    $manifest = @()
    foreach ($b in $bundles) {
        foreach ($root in @((Join-Path $profileRoot 'node_modules'), "${DshRoot}\profiles\node_modules")) {
            $dir = Join-Path $root $b
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $hit = Get-ChildItem -LiteralPath $dir -Recurse -Depth 2 -Force -File -Filter 'client.js' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($hit) { $manifest += ($b + '/' + $hit.Name) }
            break
        }
    }
    $manifest = @($manifest | Sort-Object -Unique)
    $missing = @()
    foreach ($e in $Expect) { if (-not ($manifest | Where-Object { $_ -like "*$e*" })) { $missing += $e } }
    if ($missing.Count -gt 0) { NewWarn ("plugin NOT in boot manifest (disk inventory): " + ($missing -join ', ')) }
    return [ordered]@{ count = $manifest.Count; entries = $manifest; missing = $missing; source = 'disk-inventory' }
}

function Get-BootFactHttp {
    param([string[]]$Expect, [string]$LogFile)
    $tail = Get-Content -LiteralPath $LogFile -Tail 400 -Encoding UTF8
    $tokens = @()
    foreach ($m in [regex]::Matches(($tail -join "`n"), 'token=([A-Za-z0-9_\-]+)')) { $tokens += $m.Groups[1].Value }
    $tokens = @($tokens | Select-Object -Unique)
    if ($tokens.Count -eq 0) { NewWarn 'no web token found in launcher log tail'; return $null }
    $manifest = $null; $used = $null; $err = $null
    foreach ($t in ($tokens | Select-Object -Last 3)) {
        try {
            $html = (Invoke-WebRequest -Uri "http://127.0.0.1:3080/?token=$t" -UseBasicParsing -TimeoutSec 10).Content
            if ($html -match 'client\.js') {
                $manifest = [regex]::Matches($html, '[\w\-\./]+/client\.js') | ForEach-Object { $_.Value } | Sort-Object -Unique
                $used = $t; break
            }
            $err = 'no manifest in html'
        } catch { $err = $_.Exception.Message }
    }
    if ($null -eq $manifest) { NewWarn "boot manifest fetch failed ($err)"; return $null }
    $missing = @()
    foreach ($e in $Expect) { if (-not ($manifest | Where-Object { $_ -like "*$e*" })) { $missing += $e } }
    if ($missing.Count -gt 0) { NewWarn ("plugin NOT in boot manifest (http index): " + ($missing -join ', ')) }
    return [ordered]@{ count = $manifest.Count; entries = $manifest; missing = $missing; source = 'http-index' }
}

function Get-PersonaFact {
    # Optional, deployment-specific check. With no plugin configured, or with the
    # plugin directory absent, this reports nothing at all and raises no warning.
    if ([string]::IsNullOrEmpty($script:PersonaPlugin)) { return $null }
    if (-not (Test-Path -LiteralPath "$script:ProfileRoot\plugins\$($script:PersonaPlugin)")) { return $null }
    $stampPath = "$script:ProfileRoot\plugins\$($script:PersonaPlugin)\_loaded.stamp"
    $stamp = $null
    $txt = Read-TextSafe $stampPath
    if ($null -ne $txt) {
        $m = [regex]::Match($txt, 'loaded at (\S+)')
        if ($m.Success) { try { $stamp = ([datetime]$m.Groups[1].Value).ToLocalTime() } catch { $stamp = $null } }
    }
    if ($null -eq $stamp) {
        $i = Get-Item -LiteralPath $stampPath -ErrorAction SilentlyContinue
        if ($i) { $stamp = $i.LastWriteTime; NewWarn 'stamp has no ISO time, fell back to mtime' }
        else { NewWarn "persona stamp missing: $stampPath" }
    }
    $checkPass = $null; $checkTotal = $null; $checkFail = $null
    try {
        $out = & $script:NodeExe "$script:ProfileRoot\plugins\$($script:PersonaPlugin)\check.mjs" 2>&1 | Out-String
        $pass = @($out -split "`r?`n" | Where-Object { $_ -match '^\s*\[OK\]' }).Count
        $fail = @($out -split "`r?`n" | Where-Object { $_ -match '^\s*\[FAIL\]' }).Count
        $checkPass = $pass; $checkFail = $fail; $checkTotal = $pass + $fail
        $mLen = [regex]::Match($out, 'PERSONA_SPEC \S* . (\d+)')
        if ($mLen.Success) { $script:SpecChars = $mLen.Groups[1].Value }
        if ($fail -gt 0) { NewWarn "persona check.mjs reported $fail FAIL line(s)" }
    } catch { NewWarn "persona check.mjs unrunnable: $($_.Exception.Message)" }
    return [ordered]@{ stamp = $stamp; age = (Get-AgeHours $stamp); checkPass = $checkPass; checkTotal = $checkTotal; checkFail = $checkFail; specChars = $script:SpecChars }
}

function Get-ArchiveFact {
    $rows = @()
    $missing = @()
    foreach ($f in @("${DshRoot}\AGENTS.md", "$Workspace\AGENTS.md", "$Workspace\HANDOFF.md", "${DshRoot}\handoff\handoff-state.md")) {
        $i = Get-Item -LiteralPath $f -ErrorAction SilentlyContinue
        if ($null -eq $i) { $missing += $f; continue }
        $rows += [pscustomobject]@{ name = (Split-Path $f -Leaf); path = $f; size = $i.Length; mtime = $i.LastWriteTime }
    }
    # None of them there at all = a deployment that is not set up yet, not one that
    # drifted: stay quiet instead of filing four "archive missing" warnings.
    # Partially present = something really went missing, which is worth a warning.
    if ($rows.Count -gt 0) { foreach ($f in $missing) { NewWarn "archive missing: $f" } }
    return $rows
}

# the POINTERS table in handoff-state.md: every path there gets existence-checked
function Parse-Registry {
    param([string]$StatePath)
    $txt = Read-TextSafe $StatePath
    # No state file = nothing to verify here, and no warning either: Get-ArchiveFact
    # reports a missing state file once the rest of the deployment is present.
    # (Parse-WatchFiles below already behaves this way.)
    if ($null -eq $txt) { return @() }
    $rows = @()
    $inTbl = $false
    foreach ($line in ($txt -split "`r?`n")) {
        if ($line -match '^##\s*POINTERS') { $inTbl = $true; continue }
        if ($inTbl -and ($line -match '^##\s' -or $line -match '^\s*<!--')) { break }
        if (-not $inTbl) { continue }
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { Clean-Cell $_ })
        if ($cells.Count -lt 2) { continue }
        if ($cells[0] -match '^:?-{2,}$') { continue }
        if ($cells[0] -eq 'pointer') { continue }
        $p = $cells[1]
        # skip the header row of a Chinese table: a real path always contains a separator
        if ($p -notmatch '[\\/]') { continue }
        $rows += [pscustomobject]@{ what = $cells[0]; raw = $p }
    }
    return $rows
}

# the WATCHFILES table in handoff-state.md: key files worth timestamping each run
# (kept in the state file, not here, because a few of those names are not ASCII)
function Parse-WatchFiles {
    param([string]$StatePath)
    $txt = Read-TextSafe $StatePath
    if ($null -eq $txt) { return @() }
    $rows = @()
    $inTbl = $false
    foreach ($line in ($txt -split "`r?`n")) {
        if ($line -match '^##\s*WATCHFILES') { $inTbl = $true; continue }
        if ($inTbl -and ($line -match '^##\s' -or $line -match '^\s*<!--')) { break }
        if (-not $inTbl) { continue }
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @(($line.Trim().Trim('|') -split '\|') | ForEach-Object { Clean-Cell $_ })
        if ($cells.Count -lt 2) { continue }
        if ($cells[0] -match '^:?-{2,}$') { continue }
        if ($cells[1] -notmatch '[\\/]') { continue }   # skip header rows
        $rows += [pscustomobject]@{ label = $cells[0]; raw = $cells[1] }
    }
    return $rows
}

function Resolve-RegistryPath {
    param([string]$Raw)
    $p = $Raw -replace '\$DSH_HOME', $DshRoot
    $p = $p -replace '^\.\.\.\\', "${DshRoot}\"
    $p = $p.Trim()
    if ($p -match '[<>]') { return $null }   # placeholder path, nothing to check
    if ($p -match '\*') {
        $dir = Split-Path $p -Parent
        return [pscustomobject]@{ path = $p; exists = (Test-Path -LiteralPath $dir); glob = $true }
    }
    return [pscustomobject]@{ path = $p; exists = (Test-Path -LiteralPath $p); glob = $false }
}

# ---------------------------------------------------------------- marker integrity

# The state file is sliced by regex: "<!-- STATE:X -->" ... "<!-- /STATE:X -->". A missing
# closing marker does NOT throw -- Read-StateSection silently returns an empty string, so a
# whole section disappears from HANDOFF.md while the run still reports "warnings: none".
# That failure shipped twice before the gate existed, and both times a human had to notice
# the blank section. This gate counts the eight markers: any deviation is a hard FAIL, never
# a soft warning, and it can veto the render so a broken state file cannot overwrite
# HANDOFF.md with a truncated version.
#
# Exit code 4 is the documented signal for this state (see the header comment).
$script:MarkersFatal = $false

function Test-MarkerIntegrity {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        Say 'markers       : FAIL - state file missing or unreadable'
        NewWarn 'state file missing or unreadable -> marker gate cannot run'
        $script:MarkersFatal = $true
        return
    }
    $bad = 0
    foreach ($ln in ($Text -split "`r?`n")) {
        # an inline marker quoted inside body text hijacks the section regex below
        if ($ln -match 'STATE:' -and $ln -match '<!--' -and $ln -notmatch '^\s*<!--\s*/?STATE:[A-Z]+\s*-->\s*$') { $bad++ }
    }
    $found = @()
    foreach ($k in @('STATUS', 'PENDING', 'DONE', 'SUSPENDED')) {
        $o = ([regex]::Matches($Text, '<!--\s*STATE:' + $k + '\s*-->')).Count
        $c = ([regex]::Matches($Text, '<!--\s*/STATE:' + $k + '\s*-->')).Count
        if ($o -eq 1 -and $c -eq 1) { $found += $k }
        else { Say ("markers       : FAIL - section " + $k + " has open=" + $o + " close=" + $c + " (want 1 and 1)") }
    }
    if ($bad -gt 0) { Say ("markers       : FAIL - " + $bad + ' inline STATE marker(s) inside body text') }
    if ($found.Count -eq 4 -and $bad -eq 0) {
        Say 'markers       : 8/8 OK'
        return
    }
    $script:MarkersFatal = $true
    NewWarn ('state markers broken: ' + $found.Count + '/4 sections intact, ' + $bad + ' inline marker(s) -> HANDOFF section(s) would render EMPTY')
}

# Read the state file once and keep it: the gate reads it before the collectors run, and
# the renderer needs the same text afterwards. Reset $script:StateTxt whenever the final
# path is known, so a cached read of a different path cannot leak into the render.
function Get-StateTxt {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if ($null -eq $script:StateTxt) { $script:StateTxt = Read-TextSafe $Path }
    return $script:StateTxt
}

# ---------------------------------------------------------------- gather

$statePath = "${DshRoot}\handoff\handoff-state.md"
$templatePath = "${DshRoot}\handoff\handoff-template.md"
# the cached state text must belong to the FINAL path (the gate below reads it first)
$script:StateTxt = $null
# $LogPath already set above (script writes its own log so the scheduled task needs no redirection)

Say '=== handoff check ==='
Say ("now        : " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Test-MarkerIntegrity (Get-StateTxt $statePath)

$node = Get-NodeFact
Say ("node       : " + $(if ($node) { "$($node.path) $($node.version)" } else { 'NOT FOUND' }))
$persona = Get-PersonaFact
$boot = Get-BootFact -Expect $script:BootExpect
# Skin reporting is opt-in: a deployment that uses no skins should not have to configure
# -SkinId just to silence a section it does not care about.
$skin = @()
if ($SkinId) { $skin = Get-SkinFact }
$tasks = Get-TaskFact -Names $script:MonitoredTasks
$memes = Get-MemeFact
$files = @()
foreach ($w in (Parse-WatchFiles $statePath)) {
    $wp = Resolve-RegistryPath $w.raw
    if ($null -eq $wp) { continue }
    $files += Get-FileFact $wp.path $w.label
}
$files = @($files | Where-Object { $_ })
$archives = Get-ArchiveFact
$registry = Parse-Registry $statePath
$regRows = @()
foreach ($r in $registry) {
    $rp = Resolve-RegistryPath $r.raw
    if ($null -eq $rp) { continue }
    if (-not $rp.exists) { NewWarn "registry pointer dead: $($r.what) -> $($rp.path)" }
    $regRows += [pscustomobject]@{ what = $r.what; path = $rp.path; exists = $rp.exists }
}

$renderMode = (-not $Check) -and (-not $Register)
$handoff = $archives | Where-Object { $_.path -eq "$Workspace\HANDOFF.md" } | Select-Object -First 1
$globalAgents = $archives | Where-Object { $_.path -eq "${DshRoot}\AGENTS.md" } | Select-Object -First 1
$wsAgents = $archives | Where-Object { $_.path -eq "$Workspace\AGENTS.md" } | Select-Object -First 1
$stateItem = Get-Item -LiteralPath $statePath -ErrorAction SilentlyContinue
$checkedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

if (-not $renderMode) {
    if ($handoff -and $globalAgents -and $handoff.mtime -lt $globalAgents.mtime) { NewWarn "HANDOFF.md older than global AGENTS.md (handoff $(Get-AgeHours $handoff.mtime)h vs agents $(Get-AgeHours $globalAgents.mtime)h)" }
    if ($handoff -and $wsAgents -and $handoff.mtime -lt $wsAgents.mtime) { NewWarn 'HANDOFF.md older than workspace AGENTS.md' }
    if ($handoff -and $stateItem -and $handoff.mtime -lt $stateItem.LastWriteTime) { NewWarn 'HANDOFF.md older than handoff-state.md -> run render' }
    # guard: a STATE marker quoted verbatim inside body text (even inside a code
    # block) is picked up by Read-StateSection's regex as a real boundary, so the
    # section gets sliced in half and everything after it lands in the next one -
    # while the run still says "warnings: none". Measured once: the status section
    # kept 3 of its 101 lines and the whole pending section was swallowed by the
    # done section (rendered file 112 KB -> 204 KB). Quote markers as STATE:XXX
    # without the angle brackets instead.
    $stxt = Read-TextSafe $statePath
    if ($null -ne $stxt) {
        $inline = 0
        foreach ($ln in ($stxt -split "`r?`n")) {
            if ($ln -match 'STATE:' -and $ln -match '<!--' -and $ln -notmatch '^\s*<!--\s*/?STATE:[A-Z]+\s*-->\s*$') { $inline++ }
        }
        if ($inline -gt 0) { NewWarn "handoff-state.md has $inline INLINE STATE marker(s) inside body text -> they hijack section parsing; quote them as STATE:XXX without angle brackets" }
    }
    if ($handoff) {
        $htxt = Read-TextSafe $handoff.path
        $m = [regex]::Match($htxt, 'CHECKED_AT:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
        if ($m.Success) {
            $prev = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)
            $ageH = [math]::Round((New-TimeSpan -Start $prev -End (Get-Date)).TotalHours, 1)
            Say ("last check    : $($m.Groups[1].Value)  ($ageH h ago)")
            if ($ageH -gt 24) { NewWarn "HANDOFF.md machine check is $ageH h old -> rerun handoff-check.ps1" }
        } else { NewWarn 'HANDOFF.md has no CHECKED_AT marker -> not generated by this script' }
    }
}
if ($persona -and $persona.age -gt 48) { NewWarn "persona stamp is $($persona.age)h old (service may not have been restarted since)" }

Say ''
Say '--- facts ---'
Say ("persona stamp : " + $(if ($persona.stamp) { "$($persona.stamp.ToString('yyyy-MM-dd HH:mm:ss'))  (" + $persona.age + " h old)" } else { 'unknown' }) + "  check=" + $(if ($persona.checkFail -eq 0) { 'GREEN' } elseif ($null -eq $persona.checkFail) { 'n/a' } else { 'FAIL' }) + "  pass=" + $(if ($null -ne $persona.checkTotal) { "$($persona.checkPass)/$($persona.checkTotal)" } else { 'n/a' }))
Say ("boot manifest : " + $(if ($boot) { "$($boot.count) entries, missing=" + $(if (@($boot.missing).Count -eq 0) { 'none' } else { (@($boot.missing) -join ',') }) + "  (" + $boot.source + ")" } else { 'unavailable' }))
if ($skin.Count -gt 0) { Say ("skin flags    : " + (($skin | ForEach-Object { "$($_.dir)=$($_.note)" }) -join '  |  ')) }
else { Say 'skin flags    : n/a (no -SkinId given)' }
Say ("meme assets   : " + $(if ($memes) { "$($memes.total) total (official $($memes.official), custom $($memes.custom))" } else { 'n/a' }))
foreach ($t in $tasks) { Say ("task          : {0}  exists={1}  state={2}  next={3}" -f $t.name, $t.exists, $t.state, $t.next) }
foreach ($f in $files) { Say ("file          : {0,-22} {1,8} B  {2}  ({3} h old)" -f $f.label, $f.size, $f.mtime.ToString('MM-dd HH:mm'), $f.age) }
Say ("archives      : " + (($archives | ForEach-Object { "$($_.name)@$($_.mtime.ToString('MM-dd HH:mm'))" }) -join '  |  '))
Say ("registry      : " + $regRows.Count + " pointers, dead=" + @($regRows | Where-Object { -not $_.exists }).Count)

Say ''
Say '--- warnings ---'
if ($script:Warn.Count -eq 0) { Say 'none' } else { foreach ($w in $script:Warn) { Say ("  [!] " + $w) } }

# ---------------------------------------------------------------- render

function Read-StateSection {
    param([string]$Text, [string]$Name)
    $m = [regex]::Match($Text, "(?s)<!--\s*STATE:$Name\s*-->(.*?)<!--\s*/STATE:$Name\s*-->")
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    NewWarn "handoff-state.md has no STATE:$Name section"
    return ''
}

function Render-Template {
    param([string]$Text, [int]$Mask)
    # loop: replace innermost {{#ID}}...{{/ID}} regions while they still nest
    for ($round = 0; $round -lt 6; $round++) {
        $script:regionHit = $false
        $out = [regex]::Replace($Text, '(?s)\{\{#(\d+)\}\}((?:(?!\{\{#\d+\}\}).)*?)\{\{/\1\}\}', {
                param($m)
                $script:regionHit = $true
                if (Test-IdBit $Mask ([int]$m.Groups[1].Value)) { return $m.Groups[2].Value } else { return '' }
            })
        $Text = $out
        if (-not $script:regionHit) { break }
    }
    return $Text
}

function Render-Handoff {
    $tmpl = Read-TextSafe $templatePath
    if ($null -eq $tmpl) { Say "template missing: $templatePath"; return $false }
    $stateTxt = Get-StateTxt $statePath
    if ($null -eq $stateTxt) { Say "state file missing: $statePath"; return $false }

    $txt = $tmpl
    $txt = $txt -replace '\{\{NOW\}\}', (Get-Date -Format 'yyyy-MM-dd HH:mm')
    $txt = $txt -replace '\{\{CHECKED_AT\}\}', $checkedAt
    $txt = $txt -replace '\{\{STATUS_LINE\}\}', (Read-StateSection $stateTxt 'STATUS')
    $txt = $txt -replace '\{\{PENDING\}\}', (Read-StateSection $stateTxt 'PENDING')
    $txt = $txt -replace '\{\{DONE\}\}', (Read-StateSection $stateTxt 'DONE')
    $txt = $txt -replace '\{\{SUSPENDED\}\}', (Read-StateSection $stateTxt 'SUSPENDED')
    $txt = $txt -replace '\{\{STATE_PATH\}\}', $statePath
    $txt = $txt -replace '\{\{NODE_PATH\}\}', $(if ($node) { $node.path } else { '?' })
    $txt = $txt -replace '\{\{NODE_VER\}\}', $(if ($node) { $node.version } else { '?' })
    $txt = $txt -replace '\{\{SPEC_CHARS\}\}', $(if ($script:SpecChars) { $script:SpecChars } else { '?' })
    $txt = $txt -replace '\{\{PERSONA_STAMP\}\}', $(if ($persona.stamp) { $persona.stamp.ToString('yyyy-MM-dd HH:mm:ss') } else { '?' })
    $txt = $txt -replace '\{\{PERSONA_AGE\}\}', $(if ($null -ne $persona.age) { $persona.age } else { '?' })
    $txt = $txt -replace '\{\{PERSONA_PASS\}\}', $(if ($null -ne $persona.checkTotal) { $persona.checkPass } else { '?' })
    $txt = $txt -replace '\{\{PERSONA_TOTAL\}\}', $(if ($null -ne $persona.checkTotal) { $persona.checkTotal } else { '?' })
    $txt = $txt -replace '\{\{PERSONA_FAIL\}\}', $(if ($null -ne $persona.checkFail) { $persona.checkFail } else { '?' })
    $txt = $txt -replace '\{\{BOOT_COUNT\}\}', $(if ($boot) { $boot.count } else { '?' })
    $txt = $txt -replace '\{\{BOOT_MISSING\}\}', $(if ($boot) { @($boot.missing).Count } else { '?' })
    $txt = $txt -replace '\{\{BOOT_MISSING_LIST\}\}', $(if ($boot) { (@($boot.missing) -join ', ') } else { '' })
    $txt = $txt -replace '\{\{SKIN_LAYERS\}\}', $skin.Count
    $txt = $txt -replace '\{\{SKIN_BAD\}\}', @($skin | Where-Object { $_.enabled -ne $true }).Count
    $txt = $txt -replace '\{\{MEME_COUNT\}\}', $(if ($memes) { $memes.total } else { '?' })
    $txt = $txt -replace '\{\{MEME_CUSTOM\}\}', $(if ($memes) { $memes.custom } else { '?' })
    $txt = $txt -replace '\{\{WARN_COUNT\}\}', $script:Warn.Count

    $taskWarn = @($tasks | Where-Object { -not $_.exists }).Count
    $bootMissing = $(if ($boot) { @($boot.missing).Count } else { 0 })
    $skinBad = @($skin | Where-Object { $_.enabled -ne $true }).Count
    $personaBad = $(if ($null -ne $persona.checkFail -and $persona.checkFail -gt 0) { 1 } else { 0 })

    $txt = $txt -replace '\{\{TASK_MASK\}\}', $(if ($taskWarn -eq 0) { 2 } else { 0 })
    $txt = $txt -replace '\{\{BOOT_MASK\}\}', $(if ($bootMissing -eq 0) { 128 } else { 0 })
    $txt = $txt -replace '\{\{SKIN_MASK\}\}', $(if ($skinBad -eq 0) { 128 } else { 0 })
    $txt = $txt -replace '\{\{LIGHT_MASK\}\}', $(if ($script:Warn.Count -eq 0) { 128 } else { 0 })

    # Staleness of HANDOFF.md only means something when we are NOT the writer. Render
    # mode is about to overwrite it with the current CHECKED_AT, so the file's OLD mtime
    # and old check age are meaningless there -- trusting them baked a false "this file
    # is older than ..." paragraph into every freshly rendered file.
    $staleH = 0
    $ageCheck = 0
    $staleMask = 0
    if (-not $renderMode) {
        if ($handoff -and $globalAgents) {
            $staleH = [math]::Round((New-TimeSpan -Start $handoff.mtime -End $globalAgents.mtime).TotalHours, 1)
        }
        if ($handoff) {
            $h2 = Read-TextSafe $handoff.path
            $m2 = [regex]::Match($h2, 'CHECKED_AT:\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})')
            if ($m2.Success) { $ageCheck = [math]::Round((New-TimeSpan -Start ([datetime]::ParseExact($m2.Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null)) -End (Get-Date)).TotalHours, 1) }
        }
        if ($handoff -and $globalAgents -and $handoff.mtime -lt $globalAgents.mtime) { $staleMask += 1 }
        if ($handoff -and $wsAgents -and $handoff.mtime -lt $wsAgents.mtime) { $staleMask += 2 }
        if ($handoff -and $stateItem -and $handoff.mtime -lt $stateItem.LastWriteTime) { $staleMask += 4 }
        if ($ageCheck -gt 24) { $staleMask += 8 }
    }
    $txt = $txt -replace '\{\{STALE_HANDOFF_HOURS\}\}', $staleH
    $txt = $txt -replace '\{\{CHECK_AGE_HOURS\}\}', $ageCheck
    $txt = $txt -replace '\{\{STALE_MASK\}\}', $staleMask

    $lines = @()
    foreach ($t in $tasks) { $lines += "| ``$($t.name)`` | $(if ($t.exists) { 'OK' } else { 'MISSING' }) | $($t.state) | $($t.next) |" }
    $txt = $txt -replace '\{\{TASK_ROWS\}\}', ($lines -join "`r`n")

    $lines = @()
    foreach ($f in $files) { $lines += "| ``$(Split-Path $f.path -Leaf)`` ($($f.label)) | $(Format-Bytes $f.size) | $($f.mtime.ToString('MM-dd HH:mm')) | $($f.age) h |" }
    $txt = $txt -replace '\{\{FILE_ROWS\}\}', ($lines -join "`r`n")

    $lines = @()
    foreach ($a in $archives) { $lines += "| ``$($a.name)`` | $(Split-Path (Split-Path $a.path -Parent) -Leaf) | $(Format-Bytes $a.size) | $($a.mtime.ToString('MM-dd HH:mm')) |" }
    $txt = $txt -replace '\{\{ARCHIVE_ROWS\}\}', ($lines -join "`r`n")

    $lines = @()
    foreach ($r in $regRows) { $lines += "| $($r.what) | ``$($r.path)`` | $(if ($r.exists) { 'OK' } else { 'DEAD' }) |" }
    $txt = $txt -replace '\{\{POINTER_ROWS\}\}', ($lines -join "`r`n")

    $lines = @()
    foreach ($s in $skin) { $lines += "| $($s.dir) | ``$($s.file)`` | $($s.label) |" }
    $txt = $txt -replace '\{\{SKIN_ROWS\}\}', ($lines -join "`r`n")

    if ($script:Warn.Count -eq 0) { $txt = $txt -replace '\{\{WARNINGS\}\}', 'WARN_NONE' }
    else { $txt = $txt -replace '\{\{WARNINGS\}\}', (($script:Warn | ForEach-Object { "- [ ] " + $_ }) -join "`r`n") }

    # Bit map (each condition gets its own bit; both states are represented):
    #   1 warn>0      2 all tasks OK   4 skin bad      8 boot missing
    #   16 persona bad  32 stale        64 persona stamp old   128 default/nominal
    $mask = 0
    if ($script:Warn.Count -gt 0) { $mask += 1 }
    if ($taskWarn -eq 0) { $mask += 2 }
    if ($skinBad -gt 0) { $mask += 4 }
    if ($bootMissing -gt 0) { $mask += 8 }
    if ($personaBad -gt 0) { $mask += 16 }
    if ($staleMask -gt 0) { $mask += 32 }
    if ($persona -and $persona.age -gt 48) { $mask += 64 }
    if ($script:Warn.Count -eq 0 -and $skinBad -eq 0 -and $bootMissing -eq 0 -and $personaBad -eq 0) { $mask += 128 }
    $txt = Render-Template $txt $mask

    [System.IO.File]::WriteAllText("$Workspace\HANDOFF.md", $txt, $Utf8NoBom)
    return $true
}

# write our own log (append, keep the last 400 lines) -- never rely on the scheduled
# task's shell redirection; that is one more moving part that can silently fail.
function Write-RunLog {
    if ([string]::IsNullOrEmpty($LogPath)) { return }
    try {
        $old = @()
        if (Test-Path -LiteralPath $LogPath) { $old = @(Get-Content -LiteralPath $LogPath -Encoding UTF8) }
        $all = @($old) + @($script:Log)
        if ($all.Count -gt 400) { $all = $all[($all.Count - 400)..($all.Count - 1)] }
        [System.IO.File]::WriteAllLines($LogPath, $all, $Utf8NoBom)
    } catch { }
}

function Main {
    if ($Register) {
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"${DshRoot}\handoff\handoff-check.ps1`" -Check -LogOnly" `
        -WorkingDirectory "${DshRoot}\handoff"
    # RepetitionDuration must stay inside what Task Scheduler accepts: TimeSpan::MaxValue
    # serializes to P99999999DT... and registration fails with "out of range".
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 3650)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew
    $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'DSH handoff drift check (read-only, logs to handoff-check.log)'
    try { Register-ScheduledTask -TaskName 'DSH_HandoffCheck' -InputObject $task -Force -ErrorAction Stop | Out-Null }
    catch { NewWarn "Register-ScheduledTask failed: $($_.Exception.Message)" }
    $verify = $null
    try { $verify = Get-ScheduledTask -TaskName 'DSH_HandoffCheck' -ErrorAction Stop } catch { $verify = $null }
    if ($null -ne $verify) { Say "registered scheduled task: DSH_HandoffCheck  state=$($verify.State)" }
    else { NewWarn 'DSH_HandoffCheck NOT present after registration (read-back check failed)' }
}

    if (-not $Check -and -not $Register) {
        # The marker gate has already counted the eight section markers. A broken state file
        # must NOT overwrite a good HANDOFF.md with a truncated one: skip the render and let
        # the exit code below report the problem.
        if ($script:MarkersFatal) {
            Say ''
            Say 'render : SKIPPED - state markers broken, HANDOFF.md left untouched'
        } else {
            $ok = Render-Handoff
            Say ''
            Say ("render : " + $(if ($ok) { "HANDOFF.md written ($Workspace\HANDOFF.md)" } else { 'FAILED' }))
        }
    }

    Say ("warnings: " + $script:Warn.Count)
    return 0
}

# ---------------------------------------------------------------- run

# TECH NOTE: $exitCode must be forced to a scalar.
# Say() writes through Write-Output, and everything Main() emits on the success path is
# captured by the assignment below -- so $exitCode becomes an Object[] holding one entry
# per printed line. Two consequences, both silent:
#   * ($exitCode -eq 0) on an array returns an ARRAY (@(0)), and a single-element array
#     converts to $true when that element is 0, so the warning check below never fires and
#     the documented "exit code 2 = there are warnings" contract does not hold;
#   * `exit <array>` makes PowerShell exit 0 regardless of content.
# Measured: 12 warnings produced, exit code still 0. Taking the LAST element fixes it,
# because Main() returns its status as the final thing it prints.
$fatal = $false
try {
    $exitCode = @(Main)[-1]
} catch {
    $fatal = $true
    # keep the reason even if the crash happened before the first Say
    $script:Log.Add('FATAL: ' + $_.Exception.Message) | Out-Null
    if (-not $LogOnly) { Write-Output ('FATAL: ' + $_.Exception.Message) }
} finally {
    Write-RunLog
}

# $script:Warn.Count, not $exitCode, decides 2 vs 0 -- the count cannot be inflated by
# captured output, so it is the reliable signal here. A crash is reported as 3 so that
# "clean run" and "died before it could complain" stay distinguishable.
#
# Broken section markers outrank everything: the file this run just checked may be missing
# whole sections, which is worse than any drift warning. Exit 4 is the documented signal.
if ($fatal) { exit 3 }
if ($script:MarkersFatal) { exit 4 }
if ($script:Warn.Count -gt 0) { exit 2 }
exit 0
