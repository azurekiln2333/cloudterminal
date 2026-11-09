@echo off
setlocal
cd /d "%~dp0server"
node -e "const [a,b]=process.versions.node.split('.').map(Number);process.exit(a>23||(a===23&&b>=6)?0:1)" >nul 2>&1
if errorlevel 1 (
  echo Install Node.js 24 LTS, then run this launcher again.
  pause
  exit /b 1
)
if not exist node_modules\node-pty\package.json (
  call npm ci
  if errorlevel 1 (
    pause
    exit /b 1
  )
)
node src/agent/main.ts %*
set "agent_exit=%errorlevel%"
if not "%agent_exit%"=="0" pause
exit /b %agent_exit%
