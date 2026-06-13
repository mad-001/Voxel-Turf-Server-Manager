# Voxel Turf Server Manager

Connect your [Voxel Turf](https://store.steampowered.com/app/404530/Voxel_Turf/) server to [Takaro](https://takaro.io/pricing/?via=zach550) — player events, chat bridge, server announcements, and admin control from the Takaro dashboard (and Discord).

**Full setup guide:** https://mad-001.github.io/Voxel-Turf-Server-Manager/

## Requirements

- **Voxel Turf Dedicated Server on the `1.9.9` beta branch** (Windows). The connector uses an API that does **not** exist in 1.9.8 stable — see [Get the 1.9.9 beta](#get-the-199-beta) below. This is the #1 cause of "it doesn't work."
- A free **[Takaro](https://takaro.io/pricing/?via=zach550)** account.

That's the whole list — **no Node.js, no runtime, nothing else to install.** The entire bridge is built into a single self-contained `winmm.dll` (~1 MB) and starts automatically with your server.

## Quick Start

1. [Create a Takaro account](https://takaro.io/pricing/?via=zach550)
2. Click on Game servers, Game Server Actions, Create new game server.
3. Change the **Game Server Type** to __Generic__.
4. Click the copy button at the end of your registration token.
5. [Download the latest release](https://github.com/mad-001/Voxel-Turf-Server-Manager/releases/latest) and **extract the ZIP straight into your Voxel Turf server folder.** It adds these files:

   ```
   winmm.dll                                            (server root — the bridge, self-contained)
   mods/TakaroConnector/TakaroConfig.txt                (edit this — step 6)
   mods/TakaroConnector/scripts/server_scripts.txt
   mods/TakaroConnector/scripts/server/takaro_connector.lua
   ```
6. Edit `mods/TakaroConnector/TakaroConfig.txt` → set `SERVER_NAME` and paste your `REGISTRATION_TOKEN`.
7. Start your Voxel Turf server. The mod and bridge load automatically.
8. Within a few seconds your server shows **online** in Takaro. ✅

That's it — no separate program to launch, no client mod.

## How it works

```
Voxel Turf server (1.9.9)                                              Takaro
┌───────────────────────────┐     ┌──────────────────────────┐    ┌──────────────┐
│ TakaroConnector Lua mod   │     │ winmm.dll (in-process)   │    │ Takaro Cloud │
│  · player / chat / death  │─UDP─│  · WinHTTP TLS WebSocket │──▶ │ wss://connect│
│  · inventory, kick, give  │◀UDP─│  · request/response      │◀── │  .takaro.io/ │
└───────────────────────────┘     └──────────────────────────┘    └──────────────┘
        ▲ winmm.dll in the server root IS the bridge — it loads with the game, talks to
          the Lua mod over UDP, and to Takaro over a secure WebSocket. No separate process.
```

Source for the DLL lives in [`src/`](src/) (see [`src/BUILD.md`](src/BUILD.md)).

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
