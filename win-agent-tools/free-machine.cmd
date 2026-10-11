@echo off
rem free-machine.cmd -- double-click entry point for free-machine.ps1
rem
rem WHY A .cmd SHIM: a .ps1 cannot be double-clicked into a useful window. -NoExit keeps the
rem window open after the run so the per-item results and the freed-VRAM line stay readable;
rem without it the window closes instantly and the output is lost.
rem
rem It resolves the script NEXT TO THIS FILE, so the pair can be moved anywhere together and
rem no environment variable has to be set first. Requires PowerShell 7 (pwsh) on PATH; falls
rem back to Windows PowerShell if not.
setlocal
set "PS1=%~dp0free-machine.ps1"
if not exist "%PS1%" (
  echo free-machine.ps1 not found next to this file: %PS1%
  pause
  exit /b 2
)
where pwsh >nul 2>nul
if errorlevel 1 (
  powershell -NoProfile -NoExit -ExecutionPolicy Bypass -File "%PS1%" %*
) else (
  pwsh -NoProfile -NoExit -ExecutionPolicy Bypass -File "%PS1%" %*
)
endlocal
