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
