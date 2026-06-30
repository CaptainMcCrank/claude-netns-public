#!/usr/bin/env python3
"""Minimal AF_PACKET sniffer that writes a standard pcap.

Unlike tcpdump, it never drops privileges, so it works inside a rootless
(user+net) namespace where setgroups() is denied. Captures all ethernet frames
on the given interface until it receives SIGTERM/SIGINT.

    nssniff.py <iface> <out.pcap>
"""
import socket, struct, sys, signal, time

iface, out = sys.argv[1], sys.argv[2]

s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))  # ETH_P_ALL
s.bind((iface, 0))
s.settimeout(1.0)

f = open(out, "wb")
# pcap global header (little-endian, microsecond, LINKTYPE_ETHERNET=1)
f.write(struct.pack("<IHHiIII", 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
f.flush()

running = True
def _stop(*_):
    global running
    running = False
signal.signal(signal.SIGTERM, _stop)
signal.signal(signal.SIGINT, _stop)

while running:
    try:
        data = s.recv(65535)
    except socket.timeout:
        continue
    except OSError:
        break
    t = time.time()
    sec = int(t); usec = int((t - sec) * 1_000_000)
    f.write(struct.pack("<IIII", sec, usec, len(data), len(data)))
    f.write(data)
    f.flush()

f.close()
