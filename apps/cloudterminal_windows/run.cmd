@echo off
setlocal EnableDelayedExpansion

rem ===========================================================================
rem  CloudTerminal Windows - one-command launcher with environment self-check.
rem
rem    * No Visual Studio C++ workload  -> preview the UI with
rem      `flutter run -d chrome` (the web target cannot spawn the Node sidecar,
rem      so the UI reports "cannot start background service"; that is expected,
rem      for preview only).
rem    * Visual Studio C++ workload     -> run the full desktop app
rem      with `flutter run -d windows`.
rem
rem  This script NEVER installs anything. It only checks and prints guidance.
rem  Chinese guidance lives in LAUNCH.md next to this file.
rem
rem  Dry run (self-check, does not launch Flutter):
rem      set RUN_LAUNCHER_DRY_RUN=1 && run.cmd
rem ===========================================================================

rem Work from this script's directory (apps\cloudterminal_windows).
cd /d "%~dp0"
set "APP_DIR=%CD%"

echo.
echo === CloudTerminal Windows launcher ===
echo   app dir : %APP_DIR%
echo   (see LAUNCH.md for Chinese guidance)
echo.

rem --- 1. Flutter present? ---------------------------------------------------
where flutter >nul 2>nul
if errorlevel 1 goto :no_flutter
for /f "delims=" %%v in ('call flutter --version 2^>nul ^| findstr /i "Flutter"') do (
  echo [v] %%v
  goto :flutter_done
)
:flutter_done

rem --- 2. Node.js present? (needed by the sidecar in desktop mode) -----------
where node >nul 2>nul
if errorlevel 1 (
  echo [!] Node.js not found. Desktop mode needs Node.js 24 LTS: winget install OpenJS.NodeJS.LTS
) else (
  for /f "delims=" %%n in ('node --version 2^>nul') do echo [v] Node.js %%n
)

rem --- 3. Visual Studio Windows workload? ------------------------------------
rem Prefer vswhere (Program Files (x86)\Microsoft Visual Studio\Installer).
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "HAS_VS="
if not exist "%VSWHERE%" goto :probe_doctor
for /f "usebackq delims=" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2^>nul`) do set "HAS_VS=%%i"
if defined HAS_VS goto :decide

:probe_doctor
rem Fallback: parse `flutter doctor -v` for the Windows desktop status line.
rem Failure shows as "[X] Visual Studio - develop Windows apps" plus a second
rem line "X Visual Studio not installed; ... develop Windows apps". A healthy
rem install has only "[^] Visual Studio - develop Windows apps".
rem Run doctor once into a temp file and inspect the three signals.
set "DOCTOR_OUT=%TEMP%\cloudterminal_doctor_%RANDOM%.txt"
call flutter doctor -v >"%DOCTOR_OUT%" 2>nul
findstr /i /c:"Visual Studio" "%DOCTOR_OUT%" | findstr /i /c:"develop Windows apps" >nul
if errorlevel 1 goto :doctor_cleanup
findstr /i /c:"Visual Studio not installed" "%DOCTOR_OUT%" >nul
if not errorlevel 1 goto :doctor_cleanup
findstr /c:"[X] Visual Studio" "%DOCTOR_OUT%" >nul
if not errorlevel 1 goto :doctor_cleanup
set "HAS_VS=flutter-doctor"
:doctor_cleanup
del "%DOCTOR_OUT%" >nul 2>nul

rem --- 4. Choose the target -------------------------------------------------
:decide
if not defined HAS_VS goto :no_vs

echo.
echo [OK] Visual Studio C++ toolchain detected: !HAS_VS!
echo      Launching full desktop app: flutter run -d windows
echo.
if defined RUN_LAUNCHER_DRY_RUN (
  echo [dry-run] would execute: flutter run -d windows
  exit /b 0
)
call flutter run -d windows
exit /b %errorlevel%

:no_vs
echo.
echo [X] Visual Studio "Desktop development with C++" workload not detected.
echo     Windows desktop builds are unavailable.
echo.
echo   To install it manually (this script never installs anything):
echo     winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
echo.
echo   Then reopen the terminal and check with `flutter doctor -v` for:
echo     [OK] Visual Studio - develop Windows apps
echo.
echo   Falling back to a Chrome UI preview (web target).
echo   NOTE: web cannot spawn the Node sidecar, so the UI will report
echo         "cannot start background service". That is expected; preview only.
echo.
if defined RUN_LAUNCHER_DRY_RUN (
  echo [dry-run] would execute: flutter run -d chrome
  exit /b 0
)
call flutter run -d chrome
exit /b %errorlevel%

:no_flutter
echo [X] Flutter SDK not found (flutter is not on PATH).
echo     Install Flutter, add flutter\bin to PATH, reopen the terminal:
echo       https://docs.flutter.dev/get-started/install/windows
echo.
exit /b 1
