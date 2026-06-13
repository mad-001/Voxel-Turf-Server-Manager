# VoxelTurf N_EXTERNAL UDP API

The modder added this API **specifically for the Takaro integration**. It is the
transport the bridge uses to talk to the running VoxelTurf dedicated server.

## Protocol (modder's description, verbatim)

- The server exposes an **8-bit opcode `N_EXTERNAL` (value `103`)**.
- You call **`NetworkHandler:setExternalSecret(num)`** to set a **32-bit secret**
  number on the server.
- You must send a UDP packet to the server **on the server's game port** with the
  **first 5 bytes being**: the `N_EXTERNAL` opcode byte (`103`) followed by the
  **32-bit secret** (little-endian). If the secret does not match, the message is
  **ignored**.
- If the message is accepted, the Lua function **`onExternalMessage(inAddr, message)`**
  is called:
  - `inAddr` is a struct with the **IP of the source** and a **unique connection
    identifier**.
  - `message` is a substring of the incoming packet containing the **payload**
    (everything after the 5-byte header).
- You can send a message back with **`onExternalMessageRespond(outAddr, messageOut)`**,
  where `outAddr` contains the **connection identifier**. A connection identifier is
  **only created when a valid `N_EXTERNAL` is received**.
- **There is NO reliability layer** — you must implement it on top. Be careful: even
  on **loopback** connections you can **drop UDP packets** (e.g. if the recv buffer is
  full).

## Packet layout

```
byte 0      : 0x67 (103)            N_EXTERNAL opcode
bytes 1..4  : uint32 little-endian  secret (e.g. 123456)
bytes 5..   : payload               (our connector sends JSON)
```

The game's reply also begins with the `103` opcode byte; the bridge strips that
first byte before JSON-parsing the rest.

## Notes for our implementation

- Our connector's defaults: port **5728**, secret **123456** (configurable via
  `TakaroConfig.txt`: `GAME_PORT`, `EXTERNAL_SECRET`).
- The running connector registers the secret in `takaro_connector.lua` via
  `NH:setExternalSecret(TC.EXTERNAL_SECRET)` and replies inside `onExternalMessage`.
  NOTE: this build's reply method is `NH:sendExternalMessage(handle, str)` (works in
  1.9.9 beta); the modder's spec names it `onExternalMessageRespond` — same purpose.
- **Reliability:** the bridge sends one datagram with a 5s timeout and resolves null on
  no reply. Because UDP can drop even on loopback, large or back-to-back responses are
  unreliable. This is exactly why the `help` text is now generated **in the bridge**
  (no round-trip) and why **non-idempotent commands (money/give/...) must NOT be blindly
  auto-retried** — a dropped *response* (command actually ran) would double-apply.

## Direct UDP test client (Python)

Sends a single `N_EXTERNAL` packet with payload `hello world` and prints any reply.
Useful for poking the API directly, bypassing the bridge/Takaro. NOTE: in practice the
game serves the *registered* bridge handle, so an ad-hoc client may time out while the
bridge is running.

```python
#!/usr/bin/env python3

import socket
import struct

HOST = "127.0.0.1"
PORT = 5728

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 12346))

packet = struct.pack("<BI", 103, 123456) + b"hello world"

sock.sendto(packet, (HOST, PORT))

while True:
    data, addr = sock.recvfrom(65535)
    print(f"from {addr}:")
    print(data.hex(" "))
```

## Chunk sampling / minimap (dev: SnapperTheTwig, 2026-06-13)

The dev added chunk-sampling methods to **Chunk** — useful for building a map/minimap
(e.g. for Takaro's `getMapInfo` / `getMapTile` actions). "The top of the chunk" = the
**first non-air block**.

### Methods added to Chunk
- `chunkSamples sampleHeight()` — returns the **height** at the top of the chunk.
- `chunkSamples sampleBlocks()` — returns the **blockIds** at the top of the chunk.
- `chunkMinimapSamples sampleMinimapTextures()` — returns the **minimap texture** for
  each block at the top of the chunk. Each block is a **4×4** minimap texture, so a
  **32×32 chunk → 128×128 bitmap**.

> Workflow: get a minimap from `sampleMinimapTextures()`, then **shade it by height**
> using `sampleHeight()`.

### Returned structs
```cpp
struct chunkSamples {
    int32_t x, z;
    uint8_t xs, zs;
    vector<uint16_t> data;
    inline uint16_t getValueAt(const uint8_t x, const uint8_t z) const {
        return data[x*zs + z];
    }
    inline void setValueAt(const uint8_t x, const uint8_t z, const uint16_t val) {
        data[x*zs + z] = val;
    }
};

struct chunkMinimapSamples {
    int32_t x, z;
    uint8_t xs, zs;
    vector<minimapTex> data;
    inline minimapTex getValueAt(const uint8_t x, const uint8_t z) const {
        return data[x*zs + z];
    }
    inline void setValueAt(const uint8_t x, const uint8_t z, const minimapTex val) {
        data[x*zs + z] = val;
    }
    uint8_t getNSubpixels() const { return minimapTex::MINIMAP_SZ; }
    inline uint8_t getR(const uint8_t x, const uint8_t z, const uint8_t subX, const uint8_t subZ) const {
        return getValueAt(x,z).getAsStructAt(subX, subZ).getR();
    }
    inline uint8_t getG(const uint8_t x, const uint8_t z, const uint8_t subX, const uint8_t subZ) const {
        return getValueAt(x,z).getAsStructAt(subX, subZ).getG();
    }
    inline uint8_t getB(const uint8_t x, const uint8_t z, const uint8_t subX, const uint8_t subZ) const {
        return getValueAt(x,z).getAsStructAt(subX, subZ).getB();
    }
    inline uint8_t getA(const uint8_t x, const uint8_t z, const uint8_t subX, const uint8_t subZ) const {
        return getValueAt(x,z).getAsStructAt(subX, subZ).getA();
    }

    string getBitmap(const bool xMajor) const {
        // ... (returns the chunk's minimap as a bitmap)
    }
};
```

### Minimap texture data file (dev, 2026-06-13)
The minimap textures must be **precompiled on the client** and fed to the server as a data
file before `sampleMinimapTextures()` returns real colours server-side.

> **The file is `settings/minimap_colours.dat`** — it holds the precompiled minimap colours.

So to build a server-side minimap: ensure `settings/minimap_colours.dat` is present, then
use `sampleMinimapTextures()` (colours) shaded by `sampleHeight()`.
