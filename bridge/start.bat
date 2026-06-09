@echo off
echo Starting VoxelTurf Takaro Bridge...
cd /d "%~dp0"
if not exist "TakaroConfig.txt" (
    echo ERROR: TakaroConfig.txt not found. Copy the template and fill in your tokens.
    pause
    exit /b 1
)
if not exist "node_modules" (
    echo Installing dependencies...
    npm install
)
if not exist "dist\index.js" (
    echo Building TypeScript...
    npm run build
)
node dist\index.js
pause
