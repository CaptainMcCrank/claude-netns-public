# Command Reference: claude-netns

Structured command summaries for each operation in the tutorial, ordered by narrative sequence. Each entry includes the command, what it does at the system level, prerequisites, expected output, troubleshooting, and where it fits in the guide.

---

## 1. Network Namespace Creation

### `sudo ./claude-sandbox.sh up`

**What it does:** Creates an isolated network namespace (`claudesbx`) with a virtual ethernet pair, IP addressing, DNS configuration, and NAT masquerading for internet access.

**System-level operations (in order):**
1. `ip netns add claudesbx`: creates a new network namespace (an isolated network stack in the kernel)
2. `ip link add veth-host type veth peer name veth-ns`: creates a virtual ethernet cable with two endpoints
3. `ip link set veth-ns netns claudesbx`: moves one endpoint into the namespace (removes it from the host's view)
4. `ip addr add 10.200.1.1/24 dev veth-host`: assigns an IP to the host side (this becomes the gateway)
5. `ip link set veth-host up`: activates the host side
6. `ip netns exec claudesbx ip addr add 10.200.1.2/24 dev veth-ns`: assigns an IP to the namespace side
7. `ip netns exec claudesbx ip link set veth-ns up`: activates the namespace side
8. `ip netns exec claudesbx ip link set lo up`: activates loopback inside namespace (some apps need it)
9. `ip netns exec claudesbx ip route add default via 10.200.1.1`: routes all namespace traffic through the host
10. `echo "nameserver 1.1.1.1" > /etc/netns/claudesbx/resolv.conf`: DNS resolution (auto-bind-mounted into namespace)
11. `sysctl -wq net.ipv4.ip_forward=1`: enables kernel IP forwarding between interfaces
12. `iptables -t nat -A POSTROUTING -s 10.200.1.0/24 -o <uplink> -j MASQUERADE`: NAT: rewrite source IP for outbound
13. `iptables -A FORWARD -i veth-host -o <uplink> -j ACCEPT`: allow outbound forwarding
14. `iptables -A FORWARD -i <uplink> -o veth-host -m state --state RELATED,ESTABLISHED -j ACCEPT`: allow return traffic

**Prerequisites:** Root access (sudo). `iproute2` and `iptables` installed.

**Expected output:** `namespace 'claudesbx' up. uplink=<interface_name>`

**Troubleshooting:**
- **"RTNETLINK answers: File exists"**: A namespace named `claudesbx` already exists. Run `sudo ./claude-sandbox.sh down` first, then try again.
- **No internet from namespace**: Check all three NAT components: `sysctl net.ipv4.ip_forward` should return `1`, the MASQUERADE rule should appear in `iptables -t nat -L POSTROUTING`, and FORWARD ACCEPT rules should appear in `iptables -L FORWARD`. Missing any one causes silent packet drops.
- **"Cannot find device veth-host"**: The veth pair wasn't created. Check for kernel module `veth`: `lsmod | grep veth`. Load with `modprobe veth` if needed.

**Guide section:** Isolating Claude's traffic with network namespaces

**Teardown:** `sudo ./claude-sandbox.sh down`

---

### `sudo ./claude-sandbox.sh down`

**What it does:** Removes the namespace, NAT rules, veth pair, and DNS configuration. Reverses every change made by `up`.

**System-level operations:**
1. Removes iptables NAT and FORWARD rules (using `-D` to delete specific rules)
2. `ip netns del claudesbx`: deletes the namespace and kills all processes inside it
3. `ip link del veth-host`: removes the veth pair (both ends)
4. `rm -rf /etc/netns/claudesbx`: removes the bind-mounted DNS config

**Prerequisites:** Namespace was previously created with `up`.

**Expected output:** `namespace 'claudesbx' down.`

**Troubleshooting:**
- **"Cannot remove namespace: No such file"**: Already removed, or never created. Safe to ignore.
- **Lingering iptables rules**: If `up` was run multiple times without `down`, duplicate rules may exist. Check with `iptables -t nat -L POSTROUTING -n` and `iptables -L FORWARD -n`. Remove duplicates manually with `iptables -D`.

**Guide section:** Isolating Claude's traffic with network namespaces

---

## 2. Traffic Capture

### `sudo ./claude-sandbox.sh sniff`

**What it does:** Runs tcpdump on the host side of the veth pair, writing all traffic to `claude.pcap` and printing live DNS + TLS SNI to stdout.

**System-level operations:**
1. `tcpdump -i veth-host -n -w claude.pcap -U`: captures all packets, writes immediately (`-U` unbuffered)
2. Second tcpdump instance with BPF filter `'udp port 53 or (tcp[((tcp[12]&0xf0)>>2)]=22)'`: live display of DNS queries and TLS ClientHello messages

**BPF filter breakdown:**
- `udp port 53`: matches DNS traffic
- `tcp[((tcp[12]&0xf0)>>2)]=22`: matches TCP segments where the first payload byte is `0x16` (TLS Handshake record type). The expression `tcp[12]&0xf0)>>2` calculates the TCP data offset to find where the payload starts.

**Prerequisites:** Namespace created with `up`. Root access.

**Expected output:** Live scrolling of DNS lookups and TLS handshakes. Ctrl-C to stop.

**Output file:** `claude.pcap` (binary pcap format, readable by tcpdump, Wireshark, tshark, sni.py)

**Troubleshooting:**
- **"veth-host: No such device"**: Namespace not created, or veth pair not set up. Run `up` first.
- **Zero packets captured**: No traffic flowing. Verify claude is running in the namespace (`run` in another terminal) and that NAT is working.
- **pcap file is empty**: tcpdump may have been killed before flushing. The `-U` flag should prevent this, but verify by checking file size: `ls -la claude.pcap`.

**Guide section:** Isolating Claude's traffic with network namespaces

---

### `./rootless-capture.sh "<prompt>"`

**What it does:** Creates a rootless (no-sudo) user+net+mount namespace, attaches userspace networking via slirp4netns, captures traffic with nssniff.py, runs one claude prompt, and tears down automatically.

**System-level operations (in order):**
1. `unshare --user --map-root-user --net --mount --pid --fork --kill-child`: creates rootless namespace
2. Inside namespace: `ip link set lo up`, bind-mount `resolv.conf` pointing to `10.0.2.3` (slirp4netns DNS)
3. Parent process: `slirp4netns --configure --mtu=65520 --disable-host-loopback $PID tap0`: userspace NAT via TAP interface
4. Inside namespace: `python3 nssniff.py tap0 claude.pcap`: raw socket capture on the TAP interface
5. Inside namespace: `printf '%s' "$PROMPT" | claude -p --allowedTools WebFetch WebSearch`: run claude with the prompt
6. Automatic teardown when unshare child exits (`--kill-child`)

**Prerequisites:** `slirp4netns`, `python3`, `claude` CLI. NO sudo needed.

**Expected output:** Produces `claude.pcap` and `claude-stdout.txt` in the working directory.

**Troubleshooting:**
- **"unshare: operation not permitted"**: User namespaces may be disabled. Check: `sysctl kernel.unprivileged_userns_clone`. On Debian/Ubuntu, enable with `sudo sysctl kernel.unprivileged_userns_clone=1`.
- **"slirp4netns: command not found"**: Install with `sudo apt install slirp4netns` (Debian/Ubuntu) or `sudo dnf install slirp4netns` (Fedora).
- **Empty pcap**: slirp4netns may not have configured the interface before capture started. Check `sniff.log` for errors. The script has a retry loop (100 attempts, 0.1s each) waiting for the default route.
- **claude exits immediately**: Check `claude-stdout.txt` for error messages. Common issue: claude CLI not authenticated.

**Guide section:** Isolating Claude's traffic with network namespaces (rootless alternative)

---

## 3. Traffic Analysis (Encrypted)

### `python3 sni.py claude.pcap`

**What it does:** Extracts TLS Server Name Indication (SNI) hostnames from a pcap file. Shows which hostnames the captured process connected to via TLS, mapped to destination IPs.

**How it works:**
1. Parses pcap global header (detects endianness from magic number `0xa1b2c3d4`)
2. For each packet: Ethernet (type `0x0800` = IPv4) → IP header (extract dst IP) → TCP header (calculate payload offset) → TLS record (`0x16` = Handshake) → ClientHello (`0x01`) → Extensions → SNI extension (`0x0000`)
3. Aggregates by (hostname, destination_IP) and prints sorted counts

**Prerequisites:** Python 3 (no external dependencies), a pcap file from a previous capture.

**Expected output:**
```
  8  api.anthropic.com                  -> 160.79.104.10
  3  docs.mcp.cloudflare.com            -> 104.18.24.159
  1  example.com                        -> 104.20.23.154
  1  http-intake.logs.us5.datadoghq.com -> 34.149.66.137
```

**Troubleshooting:**
- **No output**: The pcap may contain no TLS traffic (e.g., empty capture, or only DNS). Verify with `tcpdump -nr claude.pcap | head`.
- **Partial results**: Some TLS connections may use TLS 1.3 with ECH (Encrypted Client Hello), which hides the SNI. This is rare but possible for some CDN-fronted services.
- **"IndexError" or parser crash**: May indicate a non-standard pcap format or truncated capture. Verify pcap integrity with `tcpdump -nr claude.pcap | wc -l`.

**Guide section:** Extracting hostnames from encrypted traffic

---

### `tcpdump -nr claude.pcap 'udp port 53'`

**What it does:** Displays DNS query/response packets from the capture file. Shows which hostnames were resolved before TLS connections were established.

**Flags explained:**
- `-n`: don't reverse-resolve addresses (show raw IPs, faster)
- `-r claude.pcap`: read from file instead of live capture
- `'udp port 53'`: BPF filter: only DNS traffic (standard DNS uses UDP port 53)

**Prerequisites:** tcpdump, a pcap file.

**Expected output:** DNS A/AAAA queries and responses for each hostname. Typical format:
```
12:34:56.789 IP 10.200.1.2.54321 > 1.1.1.1.53: A? example.com. (29)
12:34:56.801 IP 1.1.1.1.53 > 10.200.1.2.54321: A example.com 104.20.23.154 (45)
```

**Troubleshooting:**
- **No DNS output**: If claude uses DNS-over-HTTPS (DoH) or DNS-over-TLS (DoT), standard DNS queries won't appear. Check for TCP port 853 (DoT) or HTTPS connections to known DoH providers.
- **DNS to unexpected resolver**: The namespace uses `1.1.1.1` (Cloudflare) by default. If you see queries to a different resolver, check `/etc/netns/claudesbx/resolv.conf`.

**Guide section:** Extracting hostnames from encrypted traffic

---

### `tcpdump -nr claude.pcap`

**What it does:** Displays all packets in the capture. Useful for verifying the capture is process-scoped (should show only traffic to/from the namespace's IP).

**Troubleshooting:**
- **Traffic from unexpected IPs**: If you see traffic from IPs other than `10.200.1.2` (namespace) or `10.0.2.x` (slirp), the capture may not be properly scoped. Re-check the capture interface.

**Guide section:** Extracting hostnames from encrypted traffic

---

## 4. MITM Proxy Setup

### `./claude-mitm.sh proxy`

**What it does:** Starts `mitmweb` listening on port 8080 (proxy) and 8081 (web UI). First run of any mitmproxy tool generates the CA certificate at `~/.mitmproxy/mitmproxy-ca-cert.pem`.

**System-level operations:**
1. `mitmweb --listen-port 8080 --web-port 8081`: starts the MITM proxy with web-based traffic viewer

**Prerequisites:** mitmproxy installed (`pipx install mitmproxy` or `pip install mitmproxy`).

**Expected output:** mitmweb starts. Web UI accessible at `http://127.0.0.1:8081`. Blocks the terminal (runs in foreground).

**Troubleshooting:**
- **"Address already in use"**: Port 8080 or 8081 is already bound. Kill the existing process or use a different port: edit the PORT variable in the script.
- **"mitmweb: command not found"**: mitmproxy not installed or not on PATH. If installed via pipx, ensure `~/.local/bin` is on PATH.
- **CA certificate not generated**: Run `mitmdump` once (Ctrl-C immediately). The first run of any mitmproxy tool generates the CA at `~/.mitmproxy/`.

**Guide section:** Decrypting HTTPS with a MITM proxy

---

### `./claude-mitm.sh run`

**What it does:** Launches claude with environment variables that route all HTTP(S) through the local mitmproxy and trust its CA certificate.

**Environment variables set (scoped to this process only):**
- `HTTPS_PROXY=http://127.0.0.1:8080`: route HTTPS through proxy
- `HTTP_PROXY=http://127.0.0.1:8080`: route HTTP through proxy
- `NODE_EXTRA_CA_CERTS=~/.mitmproxy/mitmproxy-ca-cert.pem`: trust proxy's CA

**Why this works:** Node.js (claude's runtime) reads proxy settings from `HTTPS_PROXY`/`HTTP_PROXY` and additional CA certificates from `NODE_EXTRA_CA_CERTS`. These are process-level environment variables: no other process on the system sees them or is affected.

**Prerequisites:** mitmproxy running (`./claude-mitm.sh proxy` in another terminal). CA file exists at `~/.mitmproxy/mitmproxy-ca-cert.pem`.

**Expected output:** claude launches normally. All its HTTPS traffic appears decrypted in the mitmweb UI.

**Troubleshooting:**
- **"CA not found"**: Run `./claude-mitm.sh proxy` (or just `mitmdump`) once first to generate the CA certificate.
- **claude shows SSL/TLS errors**: The CA may not be readable, or mitmproxy may not be running. Verify: `ls -la ~/.mitmproxy/mitmproxy-ca-cert.pem` and check that the proxy process is listening on port 8080.
- **Traffic doesn't appear in mitmweb**: Verify `HTTPS_PROXY` is set correctly. Run `env | grep PROXY` inside the claude shell to confirm.

**Guide section:** Decrypting HTTPS with a MITM proxy

---

### `./mitm-capture.sh "<prompt>"`

**What it does:** One-shot scripted MITM capture. Starts mitmdump with the logging addon, runs one claude prompt through it, writes decrypted transcript to `mitm.txt`.

**System-level operations:**
1. `mitmdump -p 8091 -q -s mitm_logger.py --set logfile=mitm.txt --set bodymax=4000`: proxy with custom Python logging addon
2. TCP probe loop waiting for proxy to accept connections (up to 5 seconds)
3. `HTTPS_PROXY=... HTTP_PROXY=... NODE_EXTRA_CA_CERTS=... printf "$PROMPT" | claude -p --allowedTools WebFetch WebSearch`: run claude non-interactively
4. Kill proxy, wait for cleanup

**Prerequisites:** mitmproxy installed. CA generated (run `mitmdump` once first).

**Expected output:** Produces `mitm.txt` (decrypted transcript) and `claude-stdout.txt` (claude's response).

**Troubleshooting:**
- **Empty mitm.txt**: The proxy may not have started before claude connected. Check `mitmdump.log` for errors. The script waits up to 5 seconds; increase the loop count in the script if needed.
- **"CA missing" error**: Run `mitmdump` once (Ctrl-C) to generate the CA.
- **Port conflict with claude-mitm.sh**:`mitm-capture.sh` uses port 8091 by default (different from `claude-mitm.sh`'s 8080). If you have both running, there's no conflict. Set `MITM_PORT` to use a different port.
- **claude exits with non-zero**: Check `claude-stdout.txt` for error messages. Common causes: not authenticated, invalid prompt, tool not allowed.

**Guide section:** Decrypting HTTPS with a MITM proxy (one-shot variant)

---

## 5. Decrypted Traffic Analysis

### `grep '^>>> ' mitm.txt`

**What it does:** Shows all outbound HTTP request lines from the decrypted transcript. Each line starts with `>>> ` followed by the method and full URL.

**Expected output:**
```
>>> GET https://example.com/
>>> POST https://api.anthropic.com/v1/messages
>>> POST https://http-intake.logs.us5.datadoghq.com/...
```

**Guide section:** Decrypting HTTPS with a MITM proxy; Classifying all of Claude's network connections

---

### `grep -A 10 '>>> GET https://example.com' mitm.txt`

**What it does:** Shows the WebFetch request with its headers (10 lines of context after the match).

**Expected output:**
```
>>> GET https://example.com/
    Accept: text/markdown, text/html, */*
    Accept-Encoding: gzip, compress, deflate, br
    User-Agent: Claude-User (claude-code/2.1.168; +https://support.anthropic.com/)
    Host: example.com
<<< 200 OK  (example.com)
    Content-Type: text/html
    ...
--- response body ---
<!doctype html>...
```

**Guide section:** Decrypting HTTPS with a MITM proxy; Classifying all of Claude's network connections

---

### `grep '>>> POST.*api.anthropic.com' mitm.txt`

**What it does:** Shows all API inference calls to Anthropic's model endpoint. These contain your prompt, tool invocations, and model responses.

**Security note:** These lines are followed by request bodies containing your prompt text and `Authorization` headers containing your API key.

**Guide section:** Classifying all of Claude's network connections

---

### `grep '>>> .*datadoghq' mitm.txt`

**What it does:** Shows telemetry/logging traffic to DataDog's intake endpoint.

**Guide section:** Classifying all of Claude's network connections

---

## 6. Cleanup

### `rm mitm.txt`

**What it does:** Deletes the decrypted transcript, which contains plaintext API credentials.

**Why this is critical:** The `Authorization: Bearer sk-ant-...` header is present in every API call to `api.anthropic.com`. This is your Anthropic API key in cleartext: anyone with this file can make API calls billed to your account. The file is `.gitignore`d but you should delete it explicitly when done.

**Guide section:** Decrypting HTTPS with a MITM proxy, Appendix

---

### `sudo ./claude-sandbox.sh down`

**What it does:** Removes namespace, NAT rules, veth pair, DNS config. See section 1 above for details.

---

## 7. Advanced: Combined Namespace + MITM

### Full isolation with decryption

```bash
# 1. Create namespace
sudo ./claude-sandbox.sh up

# 2. Start mitmproxy on the host (listening on all interfaces so namespace can reach it)
mitmweb --listen-host 0.0.0.0 --listen-port 8080 --web-port 8081

# 3. Run claude inside namespace, routed through host-side proxy
sudo ip netns exec claudesbx sudo -u $USER \
  env HOME=/home/$USER \
      HTTPS_PROXY="http://10.200.1.1:8080" \
      HTTP_PROXY="http://10.200.1.1:8080" \
      NODE_EXTRA_CA_CERTS="/home/$USER/.mitmproxy/mitmproxy-ca-cert.pem" \
  claude
```

**Key detail:** The proxy address uses `10.200.1.1` (the host side of the veth pair) because mitmproxy runs in the host namespace and the namespace reaches the host via the veth link at that IP.

**Troubleshooting:**
- **Connection refused from namespace**: mitmproxy must listen on `0.0.0.0` (all interfaces), not just `127.0.0.1`. Use `--listen-host 0.0.0.0`.
- **Certificate errors**: Ensure the `NODE_EXTRA_CA_CERTS` path is absolute and readable from inside the namespace. Since mount namespaces are NOT used with `ip netns exec`, the host filesystem is visible.

**Guide section:** Appendix B
