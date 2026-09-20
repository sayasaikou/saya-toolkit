<#
  html-shot.ps1 -- render a local HTML file to a PNG screenshot using headless Microsoft Edge.
  Why this exists: dsh-vision-router's vision_html_screenshot needs Chrome/Chromium/Edge via
  puppeteer-core, and puppeteer failed to launch the browser on this machine, so this script
  uses the plain Edge command line instead (verified working 2026-09-19).

  Usage:
    pwsh -NoProfile -File $env:DSH_HOME\html-shot.ps1 -Path "E:\path\page.html"
    pwsh -NoProfile -File $env:DSH_HOME\html-shot.ps1 -Path page.html -Out out.png -Width 1200 -Height 720

  Notes:
    - The page is copied to an ASCII temp path first, so Chinese characters / spaces in the
      source path cannot break the browser command line. Network is not disabled by this script:
      the render is local, but external resources in the page would still load.
    - Captures the viewport only (Edge --screenshot cannot do full-page without measuring height).
#>
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [string]$Out,
  [int]$Width = 1200,
  [int]$Height = 720,
  [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
if (-not (Test-Path $edge)) {
  $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
}
if (-not (Test-Path $edge)) { throw "msedge.exe not found" }

$src = (Resolve-Path -LiteralPath $Path).Path
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "source not found: $Path" }

$work = Join-Path $env:TEMP ('dsh-htmlshot-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$localHtml = Join-Path $work 'page.html'
Copy-Item -LiteralPath $src -Destination $localHtml -Force
$png = Join-Path $work 'shot.png'

$uri = 'file:///' + ($localHtml -replace '\\', '/')
$prof = Join-Path $work 'profile'
$args = @(
  '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run',
  '--no-default-browser-check', '--disable-extensions',
  "--user-data-dir=$prof",
  "--window-size=$Width,$Height",
  "--screenshot=$png",
  $uri
)

$proc = Start-Process -FilePath $edge -ArgumentList $args -NoNewWindow -Wait -PassThru `
  -RedirectStandardOutput (Join-Path $work 'stdout.log') -RedirectStandardError (Join-Path $work 'stderr.log')

$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not (Test-Path $png) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path $png)) {
  $err = ''
  $errFile = Join-Path $work 'stderr.log'
  if (Test-Path $errFile) { $err = (Get-Content $errFile -Raw) }
  throw "render failed (edge exit=$($proc.ExitCode)): $err"
}

$dest = $Out
if (-not $dest) { $dest = [IO.Path]::ChangeExtension($src, '.png') }
$destFull = [IO.Path]::GetFullPath($dest)
$destDir = Split-Path -Parent $destFull
if ($destDir -and -not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
Copy-Item -LiteralPath $png -Destination $destFull -Force

$f = Get-Item -LiteralPath $destFull
"OK  {0}  {1} bytes  {2}x{3}" -f $f.FullName, $f.Length, $Width, $Height
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
