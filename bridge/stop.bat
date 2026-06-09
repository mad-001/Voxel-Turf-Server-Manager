@echo off
echo Stopping VoxelTurf Takaro Bridge...
taskkill /F /IM node.exe /FI "WINDOWTITLE eq VoxelTurf Takaro Bridge*" 2>nul
echo Done.
