# Voxel Turf Server Manager

Connect your [Voxel Turf](https://store.steampowered.com/app/1328650/Voxel_Turf/) server to [Takaro](https://takaro.io/pricing/?via=zach550) — Discord chat bridge, server announcements, and admin control from the Takaro dashboard.

**Full setup guide:** https://mad-001.github.io/Voxel-Turf-Server-Manager/

## Quick Start

1. [Create a Takaro account](https://takaro.io/pricing/?via=zach550) and register a Generic game server.
2. [Download the latest release](https://github.com/mad-001/Voxel-Turf-Server-Manager/releases/latest) and extract the ZIP.
3. Copy `TakaroConnector/` into your VoxelTurf server's `mods/` folder.
4. Edit `TakaroConnector/TakaroConfig.txt` with your bridge URL and Takaro registration token.
5. Start your Voxel Turf server — the mod loads automatically.

## What's Included

The `TakaroConnector` folder is a server-side Lua mod. Drop it into your server's `mods/` directory — no client installation needed, no extra processes to run.

## Events

`player-connected` · `player-disconnected` · `chat-message` · `player-death`

## Actions

`sendMessage` · `sendMessageToPlayer` · `kickPlayer` · `banPlayer` · `unbanPlayer` · `giveItem` · `teleportPlayer` · `executeCommand` · `getPlayers` · `testReachability`

## Requirements

- Voxel Turf Dedicated Server (Windows)
- A [Takaro](https://takaro.io/pricing/?via=zach550) account

## License

MIT
