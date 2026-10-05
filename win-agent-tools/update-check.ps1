# update-check.ps1 -- session-start environment and plugin update check.
#
# READ ONLY. It never installs and never upgrades.
#
# WHY SO STRICT: this script exists because an auto-updating plugin once wrecked a working
# installation (ops log: main-update-error E_RESTART plus a gutted plugin directory). An
# updater that rewrites its own host can fail by silently breaking other people's files,
# which is a whole order of magnitude worse than failing to install. So this script only
# reports, and a human (or an assistant, with the owner's go-ahead) decides.
#
# Usage:
#   pwsh -NoProfile -File .\update-check.ps1
#   pwsh -NoProfile -File .\update-check.ps1 -Quiet   # one summary line
#
# Exit codes: 0 = nothing to update, 3 = updates available, 2 = check could not run.
#
# WHAT IT CHECKS
#   1. the host application itself, against the registry 'latest' tag
#   2. every registry-sourced dependency of the profile's package.json
#      (link: / file: / portal: / github: / git+ / http(s): specs are skipped on purpose --
#       a linked working copy is not something a version check can judge)
#   3. global npm CLI tools
#   4. a set of winget package ids
#
# THE APPLICATION VERSION HAS TWO SHAPES (this is why the code looks branchy)
#   * A CLI-installed host lives in the npm global root and is versioned by its
#     package.json -- check 1 reads that.
#   * A desktop/Electron host ships its own bundled runtime and updates itself through its
#     own updater. The global npm copy is then orphaned, and reporting ITS version would be
#     a permanent false "update available" against a package nobody runs. When a runtime
#     manifest is present, the version is read from there instead.
#
# PREREQUISITES
#   * winget is present if you want section 4; a missing winget is reported, not fatal.
#   * Pre-release versions are never auto-installed. Even when a registry's 'latest' tag
#     points at an alpha/beta/rc, that is a report line, not an action.
#
# ASCII ONLY: PowerShell 5.1 reads a BOM-less UTF-8 file as ANSI, so a BOM-less UTF-8 file
# containing non-ASCII text dies there.
[CmdletBinding()]
param(
    [switch]$Quiet,

    # HTTP timeout for every registry lookup.
    [int]$TimeoutSec = 8,

    # Folder that holds the host application home directory (and its log).
    # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$DshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

    # Profile folder under <DshHome>\profiles. Empty = auto-detect (desktop, else web).
    [string]$ProfileName = '',

    # npm registry used for version lookups. A mirror can be passed instead, e.g.
    # https://registry.npmmirror.com
    [string]$Registry = 'https://registry.npmjs.org',

    # Root of the npm global prefix (where the host application and CLI tools live).
    [string]$GlobalNodeModules = (Join-Path $env:APPDATA 'npm\node_modules'),

    # npm package ids whose installed version should be reported.
    [string[]]$NpmTools = @('pyright'),

    # winget package ids whose upgradability should be reported.
    [string[]]$WingetIds = @(
        'BurntSushi.ripgrep.MSVC', 'sharkdp.fd', 'jqlang.jq', '7zip.7zip',
        'astral-sh.uv', 'JohnMacFarlane.Pandoc', 'GitHub.cli', 'ImageMagick.ImageMagick'
    ),

    # [optional] Runtime manifest of a desktop/Electron host. The first existing file wins
    # and its version field is used for check 1 instead of the npm global copy, because a
    # desktop host ships its own runtime and leaves the global npm copy orphaned.
    # When empty, the common install locations below are probed. If none exists, the npm
    # global copy is used, which is correct for a CLI-only installation.
    [string[]]$CoreRuntimeManifest = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\primary-runtime\runtime.json'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness\resources\runtime\primary-runtime\runtime.json')
    ),

    # Extra manifest paths supplied by the caller (prepended to the list above).
    [string[]]$ExtraRuntimeManifest = @(),

    # JSON property that holds the version inside the runtime manifest.
    [string]$CoreRuntimeVersionField = 'desktopVersion'
)

$ErrorActionPreference = 'Continue'
$Dsh = $DshHome

# ---- which profile layout is present
# TECH NOTE: probe for the package.json rather than for the folder. An empty or partially
# removed profile directory still exists, and picking it would report "no plugins found"
# while the real profile sits right next to it -- a silent false negative.
#
# TECH NOTE: the parameter is named $Root, NOT $Home. $Home is a read-only automatic
# variable in PowerShell, and the failure mode is nasty: binding a parameter called $Home
# throws "cannot overwrite variable Home" and the function returns nothing, so the script
# keeps running with an empty profile name and reports nonsense instead of failing.
function Resolve-ProfileName([string]$Root) {
    $candidates = @()
    if ($ProfileName) { $candidates += $ProfileName }
    $candidates += @('desktop', 'web')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $Root ('profiles\' + $c + '\package.json')))) { return $c }
    }
    return ''
}

$Profile = Resolve-ProfileName $Dsh
$ProfilePj = ''
if ($Profile) { $ProfilePj = Join-Path $Dsh ('profiles\' + $Profile + '\package.json') }
$CoreDir   = Join-Path $GlobalNodeModules '@deepseek-ai\dsh'
$Log       = Join-Path $Dsh 'update-check.log'

$lines = New-Object System.Collections.Generic.List[string]
function Emit($s) { $lines.Add([string]$s) | Out-Null; if (-not $Quiet) { Write-Host $s } }

function Get-LatestVersion([string]$name) {
    try {
        $url = $Registry.TrimEnd('/') + '/' + ($name -replace '/', '%2F') + '/latest'
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec $TimeoutSec
        return (($r.Content | ConvertFrom-Json).version)
    } catch { return $null }
}

function Get-InstalledVersion([string]$dir) {
    try {
        $pj = Get-Content (Join-Path $dir 'package.json') -Raw -ErrorAction Stop | ConvertFrom-Json
        return $pj.version
    } catch { return $null }
}

function Compare-Ver([string]$a, [string]$b) {
    # true when $b is newer than $a. Unparseable input falls back to a plain string
    # comparison, so a weird tag still produces a report instead of an exception.
    try { return ([version](($b -replace '[^0-9\.].*$', '')) -gt [version](($a -replace '[^0-9\.].*$', ''))) }
    catch { return ($a -ne $b) }
}

$updates = @()
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Emit ('=== update check ' + $stamp + ' ===')

# --- 1) core application ------------------------------------------------------
# The runtime manifest of a desktop host wins over the npm global copy: the desktop host
# bundles its own runtime and updates itself, so the global copy is orphaned and comparing
# its version would raise a permanent false alarm.
$coreInstalled = $null
$coreSource = 'npm global'
foreach ($mf in (@($ExtraRuntimeManifest) + @($CoreRuntimeManifest))) {
    if ($mf -and (Test-Path $mf)) {
        try {
            $coreInstalled = (Get-Content $mf -Raw -ErrorAction Stop | ConvertFrom-Json).$CoreRuntimeVersionField
            if ($coreInstalled) { $coreSource = $mf; break }
        } catch { }
    }
}
if (-not $coreInstalled) { $coreInstalled = Get-InstalledVersion $CoreDir; $coreSource = 'npm global' }

$coreLatest = Get-LatestVersion '@deepseek-ai/dsh'
if ($coreInstalled -and $coreLatest) {
    if (Compare-Ver $coreInstalled $coreLatest) {
        Emit ('DSH core      : ' + $coreInstalled + '  -> latest ' + $coreLatest + '   UPDATE AVAILABLE')
        $updates += ('DSH core ' + $coreInstalled + ' -> ' + $coreLatest)
    } else {
        Emit ('DSH core      : ' + $coreInstalled + '  (registry latest ' + $coreLatest + ')   up to date')
    }
} else {
    Emit 'DSH core      : check skipped (registry or local manifest unreadable)'
}

# --- 2) profile dependencies --------------------------------------------------
$plugins = @()
if (-not $Profile) {
    Emit ('plugins       : no profile found under ' + (Join-Path $Dsh 'profiles'))
} else {
    try {
        $pj = Get-Content $ProfilePj -Raw -ErrorAction Stop | ConvertFrom-Json
        foreach ($prop in $pj.dependencies.PSObject.Properties) {
            $spec = [string]$prop.Value
            if ($spec -match '^(link|file|portal):' -or $spec -match '^(github|git\+|https?):') { continue }
            $plugins += $prop.Name
        }
    } catch {
        Emit ('plugins       : cannot read ' + $ProfilePj)
    }
}
$pOutdated = @()
foreach ($p in $plugins) {
    $instDir = Join-Path $Dsh ('profiles\' + $Profile + '\node_modules\' + $p)
    $inst = Get-InstalledVersion $instDir
    if (-not $inst) { continue }
    $latest = Get-LatestVersion $p
    if ($latest -and (Compare-Ver $inst $latest)) { $pOutdated += ($p + ' ' + $inst + ' -> ' + $latest) }
}
if (-not $Profile) { }
elseif ($plugins.Count -eq 0) { Emit ('plugins       : none (registry-local) found in profile ' + $Profile) }
elseif ($pOutdated.Count -eq 0) { Emit ('plugins       : ' + $plugins.Count + ' checked in profile ' + $Profile + ', all up to date') }
else {
    Emit ('plugins       : ' + $pOutdated.Count + ' update(s) available')
    foreach ($o in $pOutdated) { Emit ('   ' + $o); $updates += ('plugin ' + $o) }
}

# --- 3) global npm CLI tools --------------------------------------------------
foreach ($tool in $NpmTools) {
    $inst = Get-InstalledVersion (Join-Path $GlobalNodeModules $tool)
    $latest = Get-LatestVersion $tool
    if ($inst -and $latest) {
        if (Compare-Ver $inst $latest) {
            Emit ('npm global    : ' + $tool + ' ' + $inst + ' -> ' + $latest + '   UPDATE AVAILABLE')
            $updates += ($tool + ' ' + $inst + ' -> ' + $latest)
        } else { Emit ('npm global    : ' + $tool + ' ' + $inst + '   up to date') }
    } else { Emit ('npm global    : ' + $tool + ' check skipped') }
}

# --- 4) winget CLI set --------------------------------------------------------
try {
    # TECH NOTE: match on the package ids themselves, never on the localized table
    # headers: 'winget upgrade' is a localized command whose column titles change with the
    # system language, while the ids do not.
    $wg = (& winget upgrade --accept-source-agreements 2>&1 | Out-String)
    $hits = @()
    foreach ($id in $WingetIds) { if ($wg -match [regex]::Escape($id)) { $hits += $id } }
    if ($hits.Count -eq 0) { Emit ('winget tools  : ' + $WingetIds.Count + ' checked, none upgradable') }
    else {
        Emit ('winget tools  : ' + $hits.Count + ' upgrade(s) available: ' + ($hits -join ', '))
        foreach ($h in $hits) { $updates += ('winget ' + $h) }
    }
} catch { Emit ('winget tools  : check skipped (' + $_.Exception.Message + ')') }

# --- summary ------------------------------------------------------------------
if ($updates.Count -eq 0) {
    Emit 'RESULT: everything up to date'
    $code = 0
} else {
    Emit ('RESULT: ' + $updates.Count + ' update(s) available - report first, never auto-install')
    $code = 3
}

$lines | Out-File -FilePath $Log -Append -Encoding UTF8
if ($Quiet) { Write-Host ($lines[-1]) }
exit $code
