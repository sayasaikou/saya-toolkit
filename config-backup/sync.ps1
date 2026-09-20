<#
  sync.ps1 -- mirror DSH config / scripts / notes into a git repository

  PURPOSE
    Copy a whitelist of folders and top-level files out of the DSH home folder into the
    folder that holds this script (expected to be a git clone of YOUR OWN PRIVATE repo),
    then commit and push. Run it BEFORE editing config / persona / handoff files, so the
    last known-good state is already in the cloud. restore.ps1 pulls it back.

  USAGE
    pwsh -NoProfile -File .\sync.ps1 -Note "before persona edit"
    pwsh -NoProfile -File .\sync.ps1 -DryRun   # print every action, write nothing
    pwsh -NoProfile -File .\sync.ps1 -NoPush   # commit locally, do not push

  PREREQUISITES
    * The folder holding this script is a clone of a PRIVATE git repo with a configured
      remote (origin) and working credentials.
    * -SourceRoot (default %USERPROFILE%\.dsh) holds the DSH installation.
    * git.exe is on PATH.

  HARD RED LINE
    Credential material never enters the repository. See $DenyFiles / $DenyPatterns.
    Unless you edit this code yourself, .credentials.yaml / settings.yaml /
    lan-gate-state.json / *.log / *.bak-* can never be copied. Every refusal is printed
    as DENIED, so -DryRun shows the real filter behaviour before anything is written.

  FILE FORMAT
    ASCII only, LF line endings, no BOM. Windows PowerShell 5.1 parses a BOM-less UTF-8
    file as ANSI, so every script that Task Scheduler may launch must stay ASCII.
#>
[CmdletBinding()]
param(
  # DSH home folder (mirror source).
  # $env:DSH_HOME wins when it is set; otherwise the usual per-user location is used.
  [string]$SourceRoot = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }),

  # Git clone that receives the mirror. Empty = the folder holding this script.
  [string]$RepoDir = '',

  # Optional workspace-level notes file, mirrored as workspace-AGENTS.md so it cannot be
  # confused with the copy that lives inside the DSH home. Empty = skip that step.
  # A sensible value is (Join-Path $env:DSH_WORKSPACE 'AGENTS.md').
  [string]$WorkspaceAgents = '',

  # Free text appended to the commit message.
  [string]$Note = '',

  [switch]$DryRun,
  [switch]$NoPush
)

$ErrorActionPreference = 'Continue'

# TECH NOTE: do not default a parameter to $PSScriptRoot. Resolve it in the body once,
# so the script stays safe when it is dot-sourced or run from an unexpected host.
if (-not $RepoDir) { $RepoDir = $PSScriptRoot }

$Dsh      = $SourceRoot
$Repo     = $RepoDir
$WsAgents = $WorkspaceAgents

# ---- folders mirrored recursively (missing ones are skipped silently)
$DirList = @(
  'comfy-tools', 'blender-tools', 'ppt-tools', 'gui-patches', 'gui-probes',
  'handoff', 'persona', 'archive', '.agent-presets'
)

# ---- top-level files mirrored by extension
$TopExt = @('.ps1', '.py', '.js', '.mjs', '.cs', '.vbs', '.exe', '.json', '.md', '.txt')

# ---- red line 1: these file names are never mirrored
$DenyFiles = @(
  '.credentials.yaml', 'settings.yaml', 'settings.yaml.bak',
  '.anonymous-user-id', 'lan-gate-state.json',
  'restore-full-verdict.json', '_SNAPSHOT.json', '_SYSTEM-STATE.txt'
)

# ---- red line 2: relative paths matching any of these regexes are never mirrored
# TECH NOTE: '\node_modules\' needs doubled backslashes because this is a regex, not a
# wildcard. A single backslash would escape the next character and silently match nothing.
$DenyPatterns = @('\.bak-', '\.bak$', '\.log$', '__pycache__', '\.pyc$', '\\node_modules\\', '^_probe')

function Test-Denied([string]$rel) {
  foreach ($p in $DenyPatterns) { if ($rel -match $p) { return $true } }
  $leaf = Split-Path $rel -Leaf
  foreach ($f in $DenyFiles) { if ($leaf -eq $f) { return $true } }
  return $false
}

$script:copied = 0
$script:denied = 0

function Copy-One([string]$src, [string]$relDst) {
  if (Test-Denied $relDst) { $script:denied++; Write-Host ('  DENIED  ' + $relDst) -ForegroundColor DarkYellow; return }
  if ($DryRun) { Write-Host ('  [dry]   ' + $relDst); $script:copied++; return }
  $dst = Join-Path $Repo $relDst
  $dir = Split-Path $dst -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Copy-Item -LiteralPath $src -Destination $dst -Force
  $script:copied++
}

Write-Host '=== sync.ps1 ===' -ForegroundColor Cyan
Write-Host ('repo  : ' + $Repo)
Write-Host ('source: ' + $Dsh)
if ($DryRun) { Write-Host 'mode  : DRY RUN (nothing is written, nothing is pushed)' -ForegroundColor Yellow }

# 1) top-level DSH files
Get-ChildItem $Dsh -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $TopExt -contains $_.Extension } |
  ForEach-Object { Copy-One $_.FullName $_.Name }

# 2) whitelisted folders, mirrored with their relative path preserved
foreach ($d in $DirList) {
  $srcDir = Join-Path $Dsh $d
  if (-not (Test-Path $srcDir)) { continue }
  Get-ChildItem $srcDir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($Dsh.Length + 1)
    Copy-One $_.FullName $rel
  }
}

# 3) workspace notes, stored under a different name on purpose
if ($WsAgents) {
  if (Test-Path $WsAgents) { Copy-One $WsAgents 'workspace-AGENTS.md' }
  else { Write-Host ('  SKIP    workspace notes not found: ' + $WsAgents) -ForegroundColor DarkGray }
} else {
  Write-Host '  SKIP    workspace notes (-WorkspaceAgents not set)' -ForegroundColor DarkGray
}

Write-Host ('copied = ' + $script:copied + '   denied = ' + $script:denied) -ForegroundColor Cyan

if ($DryRun) { Write-Host 'DRY RUN finished: nothing written, nothing pushed.' -ForegroundColor Yellow; return }

# 4) git commit + push
# TECH NOTE: push with an explicit refspec ('git push -u origin HEAD') so a detached or
# freshly re-cloned checkout still pushes to the branch you are actually on.
Push-Location $Repo
try {
  & git add -A 2>&1 | Out-Null
  $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $msg = if ($Note) { 'sync: ' + $Note + ' @ ' + $stamp } else { 'sync @ ' + $stamp }
  $status = & git status --porcelain
  if ($status) {
    & git commit -m $msg 2>&1 | Select-Object -First 3 | ForEach-Object { '  ' + $_ }
    Write-Host ('committed: ' + $msg) -ForegroundColor Green
  } else {
    Write-Host 'no changes to commit' -ForegroundColor DarkGray
  }
  if (-not $NoPush) {
    & git push -u origin HEAD 2>&1 | Select-Object -Last 4 | ForEach-Object { '  ' + $_ }
    if ($LASTEXITCODE -eq 0) { Write-Host 'pushed OK' -ForegroundColor Green }
    else { Write-Host ('push FAILED (exit ' + $LASTEXITCODE + ')') -ForegroundColor Red }
  } else { Write-Host 'skip push (-NoPush)' -ForegroundColor DarkGray }
} finally { Pop-Location }
