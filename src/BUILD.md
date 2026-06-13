# Building `winmm.dll`

`winmm.dll` is a `winmm` DLL proxy that **also contains the whole Takaro bridge**
(no separate `bridge.exe`, no Node). It connects to Takaro over a native WinHTTP
secure WebSocket and to the game over the N_EXTERNAL UDP API.

## Files
- `winmm.cpp` — the winmm proxy (forwards every winmm export to the real
  `System32\winmm.dll`) + a launcher thread that starts the bridge.
- `takaro_bridge.cpp` — the bridge itself (config, WebSocket, UDP, events, console).
- `json.hpp` — vendored [nlohmann/json](https://github.com/nlohmann/json) single header.
- `winmm.def` — the export list for the proxy.

## Build (MinGW-w64, GCC 13+)
```sh
x86_64-w64-mingw32-g++ -O2 -std=c++17 -shared \
  -static -static-libgcc -static-libstdc++ \
  -DWINVER=0x0A00 -D_WIN32_WINNT=0x0A00 \
  -o winmm.dll winmm.cpp takaro_bridge.cpp winmm.def \
  -lwinhttp -lws2_32
```

Notes:
- **Do NOT** link `-lwinmm` (this DLL *replaces* winmm; it forwards at runtime via
  `LoadLibrary`/`GetProcAddress`).
- The `-Wattributes` warnings (≈164) are expected — the proxy redeclares the winmm
  functions without `dllimport`.
- Static linking means the result depends only on system DLLs
  (`KERNEL32`, `WINHTTP`, `WS2_32`, `msvcrt`) — no MinGW runtime needed. ~1 MB.

## Runtime layout
```
<server root>/winmm.dll
<server root>/mods/TakaroConnector/TakaroConfig.txt
<server root>/mods/TakaroConnector/scripts/server_scripts.txt
<server root>/mods/TakaroConnector/scripts/server/takaro_connector.lua
```
The DLL reads `mods/TakaroConnector/TakaroConfig.txt`, writes
`mods/TakaroConnector/bridge.log`, and watches `logs/server_status.txt` +
`savegames/` for the start/save events.
```
