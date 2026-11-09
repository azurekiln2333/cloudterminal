#!/bin/sh
set -eu
cd "$(dirname "$0")/server"
if ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>23||(a===23&&b>=6)?0:1)' 2>/dev/null; then
  echo 'Install Node.js 24 LTS, then run this launcher again.' >&2
  exit 1
fi
if [ ! -f node_modules/node-pty/package.json ]; then npm ci; fi
exec node src/agent/main.ts "$@"
