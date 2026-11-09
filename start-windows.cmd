@echo off
rem CloudTerminal Windows connection assistant launcher.
rem
rem Starts the Flutter Windows client, which in turn runs the Node sidecar.
rem Prefer building/running the release binary under
rem apps\cloudterminal_windows\build\windows\x64\runner\Release\.
setlocal
cd /d "%~dp0"

where flutter >nul 2>&1
if errorlevel 1 (
  echo Flutter is not on PATH. Install Flutter 3.27+ and retry.
  pause
  exit /b 1
)

cd apps\cloudterminal_windows
call flutter pub get
if errorlevel 1 ( pause & exit /b 1 )

rem Prefer the native Windows target; fall back to a UI preview in Chrome when the
rem Visual Studio C++ workload is missing (the sidecar needs Windows to run).
call flutter doctor -v 2>nul | findstr /C:"Visual Studio" | findstr /C:"develop Windows apps" | findstr /V /C:"X Visual Studio" >nul
if errorlevel 1 (
  echo.
  echo Visual Studio C++ workload not found: previewing the UI in Chrome.
  echo The background service needs the Windows target. To enable it run:
  echo   winget install Microsoft.VisualStudio.2022.BuildTools --override "--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  echo.
  call flutter run -d chrome
) else (
  call flutter run -d windows
)
