@echo off
rem ============================================================
rem  run-env.cmd -- launcher for the dsh-env-bootstrap scripts.
rem
rem  Why this exists: on a default Windows box the PowerShell
rem  ExecutionPolicy is Restricted, so .ps1 files refuse to run
rem  (this is exactly why "dsh.ps1" fails and "dsh.cmd" works).
rem  This launcher re-invokes PowerShell with -ExecutionPolicy
rem  Bypass, which does not require changing machine policy.
rem
rem  Usage:
rem    run-env.cmd verify
rem    run-env.cmd export
rem    run-env.cmd apply -DryRun
rem ============================================================
setlocal EnableExtensions EnableDelayedExpansion
set "DIR=%~dp0scripts\"
set "ACTION=%~1"

if /I "%ACTION%"=="verify" set "PS=%DIR%verify-env.ps1"
if /I "%ACTION%"=="export" set "PS=%DIR%export-env.ps1"
if /I "%ACTION%"=="apply"  set "PS=%DIR%apply-env.ps1"

if not defined PS (
  echo usage: run-env.cmd verify ^| export ^| apply [extra args]
  echo   verify            read-only environment check ^(safe, run this first^)
  echo   export            snapshot the live environment to JSON + diff vs baseline
  echo   apply [-DryRun]   rebuild missing plugins/bundles/patch entries
  exit /b 2
)

shift
set "ARGS="
:collect
if "%~1"=="" goto run
set "ARGS=!ARGS! %1"
shift
goto collect

:run
set "PSEXE=powershell"
where pwsh >nul 2>nul
if not errorlevel 1 set "PSEXE=pwsh"

"%PSEXE%" -NoProfile -ExecutionPolicy Bypass -File "%PS%" !ARGS!
exit /b %ERRORLEVEL%
