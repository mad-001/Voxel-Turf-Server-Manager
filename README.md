# Voxel Turf Server Manager

Connect your [Voxel Turf](https://store.steampowered.com/app/1328650/Voxel_Turf/) server to [Takaro](https://takaro.io/pricing/?via=zach550) — Discord chat bridge, server announcements, and admin control from the Takaro dashboard.

**Full setup guide:** https://mad-001.github.io/Voxel-Turf-Server-Manager/

## Quick Start

1. [Create a Takaro account](https://takaro.io/pricing/?via=zach550) and register a Generic game server to get your registration token.
2. [Download the latest release](https://github.com/mad-001/Voxel-Turf-Server-Manager/releases/latest) and extract the ZIP.
3. Copy `TakaroConnector/` into your VoxelTurf server's `mods/` folder.
4. In `VoxelTurf-Bridge/TakaroConfig.txt`, set your `SERVER_NAME` and `REGISTRATION_TOKEN`.
5. Double-click `VoxelTurf-Bridge/start.bat` to start the bridge.
6. Start your Voxel Turf server — the mod loads automatically.

## What's Included

| Folder | Contents |
|---|---|
| `TakaroConnector/` | Lua mod — drop into your server's `mods/` folder |
| `VoxelTurf-Bridge/` | Node.js bridge — run on the same machine as the server |
| `docs/` | GitHub Pages source |

## Events

`player-connected` · `player-disconnected` · `chat-message` · `player-death`

## Actions

`sendMessage` · `sendMessageToPlayer` · `kickPlayer` · `banPlayer` · `unbanPlayer` · `giveItem` · `teleportPlayer` · `executeCommand` · `getPlayers` · `testReachability`

## Requirements

- Voxel Turf Dedicated Server (Windows)
- [Node.js 18+](https://nodejs.org) (for the bridge)
- A [Takaro](https://takaro.io/pricing/?via=zach550) account

## License

MIT
