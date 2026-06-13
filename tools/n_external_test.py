#!/usr/bin/env python3
# Direct VoxelTurf N_EXTERNAL UDP test client (modder-provided).
# Sends one N_EXTERNAL packet (opcode 103 + 32-bit secret) with payload "hello world"
# and prints any reply. See docs/N_EXTERNAL_API.md.
# NOTE: while the bridge is running the game serves the registered bridge handle, so an
# ad-hoc client may time out. Mainly useful when the bridge is stopped.

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
