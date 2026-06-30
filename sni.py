#!/usr/bin/env python3
"""Extract TLS SNI (server names) and their destination IPs from a pcap.

Pure-stdlib parse of Ethernet/IPv4/TCP + TLS ClientHello. Good enough to see
which hostnames a capture connected to. Usage: sni.py <file.pcap>
"""
import struct, sys, collections

def parse_clienthello_sni(payload):
    # payload starts at TLS record header
    if len(payload) < 5 or payload[0] != 0x16:  # handshake
        return None
    # record: type(1) ver(2) len(2)
    pos = 5
    if len(payload) < pos + 4 or payload[pos] != 0x01:  # ClientHello
        return None
    # handshake: type(1) len(3) ver(2) random(32)
    pos += 4 + 2 + 32
    if pos >= len(payload):
        return None
    sid_len = payload[pos]; pos += 1 + sid_len
    if pos + 2 > len(payload):
        return None
    cs_len = struct.unpack(">H", payload[pos:pos+2])[0]; pos += 2 + cs_len
    if pos >= len(payload):
        return None
    comp_len = payload[pos]; pos += 1 + comp_len
    if pos + 2 > len(payload):
        return None
    ext_total = struct.unpack(">H", payload[pos:pos+2])[0]; pos += 2
    end = min(len(payload), pos + ext_total)
    while pos + 4 <= end:
        etype, elen = struct.unpack(">HH", payload[pos:pos+4]); pos += 4
        if etype == 0x0000:  # server_name
            # server_name_list len(2), type(1), name_len(2), name
            try:
                nlen = struct.unpack(">H", payload[pos+3:pos+5])[0]
                return payload[pos+5:pos+5+nlen].decode("ascii", "replace")
            except Exception:
                return None
        pos += elen
    return None

def pcap_records(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        if len(gh) < 24:
            return
        magic = struct.unpack("<I", gh[:4])[0]
        le = magic in (0xa1b2c3d4, 0xa1b23c4d)
        end = "<" if le else ">"
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                return
            _, _, caplen, _ = struct.unpack(end + "IIII", rh)
            yield f.read(caplen)

def main(path):
    found = collections.OrderedDict()
    for pkt in pcap_records(path):
        if len(pkt) < 14:
            continue
        eth_type = struct.unpack(">H", pkt[12:14])[0]
        off = 14
        if eth_type != 0x0800:  # IPv4 only
            continue
        if len(pkt) < off + 20:
            continue
        ihl = (pkt[off] & 0x0f) * 4
        proto = pkt[off+9]
        dst = ".".join(str(b) for b in pkt[off+16:off+20])
        if proto != 6:  # TCP
            continue
        toff = off + ihl
        if len(pkt) < toff + 20:
            continue
        doff = ((pkt[toff+12] & 0xf0) >> 4) * 4
        payload = pkt[toff+doff:]
        sni = parse_clienthello_sni(payload)
        if sni:
            found[(sni, dst)] = found.get((sni, dst), 0) + 1
    for (sni, dst), n in found.items():
        print(f"{n:3d}  {sni:42s} -> {dst}")

if __name__ == "__main__":
    main(sys.argv[1])
