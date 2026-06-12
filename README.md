# Voxel Turf Server Manager

Connect your [Voxel Turf](https://store.steampowered.com/app/404530/Voxel_Turf/) server to [Takaro](https://takaro.io/pricing/?via=zach550) — player events, chat bridge, server announcements, and admin control from the Takaro dashboard (and Discord).

**Full setup guide:** https://mad-001.github.io/Voxel-Turf-Server-Manager/

## Requirements

- **Voxel Turf Dedicated Server on the `1.9.9` beta branch** (Windows). The connector uses an API that does **not** exist in 1.9.8 stable — see [Get the 1.9.9 beta](#get-the-199-beta) below. This is the #1 cause of "it doesn't work."
- A free **[Takaro](https://takaro.io/pricing/?via=zach550)** account.

That's the whole list — **no Node.js, no runtime, nothing else to install.** The bridge ships as a self-contained `bridge.exe` and starts automatically with your server.

## Quick Start

1. [Create a Takaro account](https://takaro.io/pricing/?via=zach550), add a **Generic** game server, and copy its **Registration Token**.
2. [Download the latest release](https://github.com/mad-001/Voxel-Turf-Server-Manager/releases/latest) and **extract the ZIP straight into your Voxel Turf server folder**. This drops two things into place:
   - `winmm.dll` in the server **root** (this auto-starts the bridge), and
   - `mods/TakaroConnector/` (the Lua mod + bridge).
3. Edit `mods/TakaroConnector/TakaroConfig.txt` → set `SERVER_NAME` and paste your `REGISTRATION_TOKEN`.
4. Start your Voxel Turf server. The mod and bridge load automatically.
5. Within a few seconds your server shows **online** in Takaro. ✅

That's it — no separate program to launch, no client mod.

## How it works

```
Voxel Turf server (1.9.9)         bridge.exe (auto-launched)           Takaro
┌───────────────────────────┐     ┌──────────────────────────┐    ┌──────────────┐
│ TakaroConnector Lua mod   │     │ bridge.js                │    │ Takaro Cloud │
│  · player / chat / death  │─UDP─│  · WebSocket client      │──▶ │ wss://connect│
│  · inventory, kick, give  │◀UDP─│  · request/response      │◀── │  .takaro.io/ │
└───────────────────────────┘     └──────────────────────────┘    └──────────────┘
        ▲ winmm.dll in the server root launches bridge.js and shuts it down with the game.
```

## Events sent to Takaro

`player-connected` (join) · `player-disconnected` (leave) · `chat-message` · `player-death` · plus **server start / stop / save** and any log line as `log` events.

Every player carries **player id** (`gameId`), **steam name** (`name`), and **steam id** (`steamId`).

## Actions Takaro can run

`getPlayers` · `testReachability` · `getPlayerInventory` · `sendMessage` · `sendMessageToPlayer` · `kickPlayer` · `banPlayer` · `unbanPlayer` · `giveItem` · `teleportPlayer` · `executeCommand`

## Get the 1.9.9 beta

In SteamCMD (dedicated server app id `526340`):

```
force_install_dir C:\path\to\your\voxelturf\server
login anonymous
app_update 526340 -beta beta
quit
```

The `beta` branch ("Public Beta") is 1.9.9 — no password. Run it **without** `validate` so it leaves the mod files alone. Verify afterwards that the version is 1.9.9.

> ⚠️ A normal Steam update (without `-beta beta`) reverts to 1.9.8 and breaks the connector — always pin `-beta beta`.

## License

MIT
