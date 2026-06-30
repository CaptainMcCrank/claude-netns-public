# claude-netns

Observe exactly what network requests the `claude` CLI makes — by running the
binary inside an isolated Linux **network namespace** so a packet capture sees
*only* its traffic, nothing else on the machine.

## The problem this solves

You want to answer questions like *"when Claude Code fetches a web page or runs a
search, where do those requests actually go, and what's in them?"*

Two things make that harder than it sounds:

1. **`tcpdump` filters by network interface, not by process.** There is no native
   "capture this one PID" on Linux. If you just `tcpdump -i eth0`, you get every
   browser tab, every background updater, and every other process on the box mixed
   in with `claude`. Picking out one program's flows by hand is painful and
   error-prone.

2. **`claude` speaks HTTPS.** A raw capture shows encrypted bytes. You can see
   *destinations* (IP addresses, and hostnames leaked via the TLS SNI field) but
   not the request paths, headers, or bodies.

This repo handles both:

- **`claude-sandbox.sh`** puts `claude` in its own network namespace with a
  dedicated virtual interface. Everything that process sends crosses one veth link
  and *only* that process's traffic does — so `tcpdump` on that link is a clean,
  process-scoped capture. Great for answering *"what hosts does it talk to?"*

- **`claude-mitm.sh`** routes `claude` through a local
  [mitmproxy](https://mitmproxy.org/) that terminates TLS, with Node configured to
  trust the proxy's CA. This gives you the **decrypted** request/response content —
  the actual URLs being scraped, headers, and bodies.

> **Heads-up on where "scraping" happens.** Claude Code's web fetch/search tools
> are often executed *server-side* by Anthropic, not from your machine. So you may
> find the only outbound destination is `api.anthropic.com`, with the page fetch
> happening on Anthropic's infrastructure rather than locally. That's itself a
> useful finding — and these tools let you confirm it rather than guess.

## Two ways to run it

- **Rootless (recommended, no `sudo`)** — `rootless-capture.sh` builds a
  user+net+mount namespace as your normal user, attaches `slirp4netns` for
  userspace networking, captures with a small raw-socket sniffer, and runs one
  `claude` prompt inside it. One command, no password, automatic teardown. This is
  the one that "just works."
- **Privileged (`sudo`)** — `claude-sandbox.sh` uses a real root network namespace
  + `iptables` NAT and lets you drive `claude` interactively for as long as you
  like. Use this when you want a live session rather than a single scripted prompt.

> **Why a custom sniffer instead of tcpdump (rootless)?** Inside a `--map-root-user`
> namespace the kernel denies `setgroups()`, and `tcpdump` insists on dropping
> privileges at startup (calling `setgroups`), so it bails out and captures zero
> packets — even with `-Z root`. `nssniff.py` opens an `AF_PACKET` socket and never
> drops privileges, so it works. In the privileged path, regular `tcpdump` is fine.

## Requirements

- Linux with network namespace support (any modern kernel)
- `tcpdump`, `iproute2` (`ip`), `iptables` — preinstalled on most distros
- `sudo` (namespaces and packet capture need root)
- For decrypted content: `mitmproxy` — `pipx install mitmproxy` or `pip install mitmproxy`
- The `claude` CLI on your `PATH`

## Install

```bash
git clone git@github.com:CaptainMcCrank/claude-netns-public.git
cd claude-netns-public
chmod +x claude-sandbox.sh claude-mitm.sh
```

## Usage

### Rootless one-shot capture (no sudo)

```bash
./rootless-capture.sh "Use the WebFetch tool to fetch https://example.com and tell me the page title."
```

Produces `claude.pcap` (the capture) and `claude-stdout.txt` (claude's reply).
Then map the encrypted connections to hostnames:

```bash
python3 sni.py claude.pcap                 # TLS SNI -> dest IP, one line per host
tcpdump -nr claude.pcap 'udp port 53'      # DNS lookups
```

Example output from a real run (claude fetching example.com):

```
  8  api.anthropic.com                  -> 160.79.104.10     # the model API
  3  docs.mcp.cloudflare.com            -> 104.18.24.159     # a configured MCP server, pinged at startup
  1  example.com                        -> 104.20.23.154     # <-- the WebFetch, made DIRECTLY from this machine
  1  http-intake.logs.us5.datadoghq.com -> 34.149.66.137     # telemetry/logging
```

**Finding:** `WebFetch` scrapes from the local CLI — there's a direct TLS
connection (SNI `example.com`) straight to the target's real IP. It is *not*
proxied server-side through `api.anthropic.com`.

### A. See where claude connects (encrypted, destinations only) — privileged

Terminal 1 — bring up the sandbox and start capturing:

```bash
sudo ./claude-sandbox.sh up
sudo ./claude-sandbox.sh sniff      # writes claude.pcap, prints live DNS + TLS SNI
```

Terminal 2 — run claude inside the namespace (uses your normal config/creds):

```bash
sudo ./claude-sandbox.sh run
```

Drive claude as usual (e.g. ask it to fetch a URL or run a web search). Watch the
live hostnames scroll in Terminal 1. When done:

```bash
sudo ./claude-sandbox.sh down       # remove namespace, NAT rules, veth
```

Inspect the full capture afterward:

```bash
tcpdump -nr claude.pcap                       # everything
tcpdump -nr claude.pcap 'udp port 53'         # DNS lookups
# or open claude.pcap in Wireshark and filter: tls.handshake.extensions_server_name
```

### B. See the actual requests (decrypted content)

```bash
# one-time: generate the proxy CA
./claude-mitm.sh proxy        # leave running; browse captures at http://127.0.0.1:8081
```

In another terminal:

```bash
./claude-mitm.sh run          # claude routed through the proxy, trusting its CA
```

Every HTTPS request claude makes now shows up decrypted in the mitmweb UI —
method, URL, headers, and body.

#### Scripted one-shot (decrypted, no UI)

`mitm-capture.sh` runs a single prompt through `mitmdump` + the `mitm_logger.py`
addon and writes a plain-text transcript to `mitm.txt`:

```bash
./mitm-capture.sh "Use the WebFetch tool to fetch https://example.com and report the title."
grep '^>>> ' mitm.txt          # every request line
less mitm.txt                  # full headers + bodies
```

Real captured WebFetch request (the actual bytes claude sent to scrape the page):

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
<!doctype html><html lang="en"><head><title>Example Domain</title>...
```

**Findings from decrypted traffic:**
- WebFetch scrapes with a distinctive `User-Agent: Claude-User (claude-code/<ver>; ...)`
  and prefers `text/markdown` (it asks the site for markdown first).
- The page is fetched **directly from your machine**, confirming the SNI evidence above.
- Other live flows seen: `POST api.anthropic.com` (the model calls),
  `docs.mcp.cloudflare.com` (a configured MCP server, contacted at startup), and
  `http-intake.logs.us5.datadoghq.com` (telemetry).

> ⚠️ **`mitm.txt` contains decrypted secrets** — your `Authorization` bearer token
> to `api.anthropic.com` is in there in cleartext. It is `.gitignore`d; do not
> share it. Delete it when done: `rm mitm.txt`.

> You can combine both: run mitmproxy and route the *namespaced* claude through it
> for full isolation **and** decryption. The simple path above is enough for most
> investigations.

## How it works

`claude-sandbox.sh up` creates a namespace `claudesbx`, a `veth` pair, gives the
namespace `10.200.1.2/24` with a default route to the host (`10.200.1.1`), points
its DNS at `1.1.1.1`, and masquerades (NATs) its traffic out the host's real
uplink. Because the namespace's only path to the outside world is the host side of
the veth pair, capturing on that interface yields a capture containing exactly the
namespaced process's packets and nothing else.

`down` reverses every change (NAT rules, forwarding rules, the namespace, the veth,
and the per-namespace resolv.conf).

## Safety notes

- These scripts only add a namespace + scoped NAT/forward rules and remove them on
  `down`. They don't touch your existing firewall rules.
- `claude-mitm.sh` makes Node trust a local CA **only** for the `claude` process it
  launches (via `NODE_EXTRA_CA_CERTS`); it does not install the CA system-wide.
- Use this on machines and accounts you own, for understanding your own tooling.
