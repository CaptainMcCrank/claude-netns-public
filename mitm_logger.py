"""mitmproxy addon: log decrypted HTTP(S) request/response to a file.

Used by mitm-capture.sh. Writes a human-readable transcript of every flow,
with request headers + body and response status/headers + a body preview.

    mitmdump -s mitm_logger.py --set logfile=mitm.txt --set bodymax=2000
"""
from mitmproxy import http, ctx

def load(loader):
    loader.add_option("logfile", str, "mitm.txt", "transcript output path")
    loader.add_option("bodymax", int, 2000, "max body bytes to record")

def _w(line=""):
    with open(ctx.options.logfile, "a") as f:
        f.write(line + "\n")

def _body(raw):
    n = ctx.options.bodymax
    if not raw:
        return "(empty)"
    text = raw[:n].decode("utf-8", "replace")
    more = "" if len(raw) <= n else f"\n... [+{len(raw)-n} more bytes]"
    return text + more

def request(flow: http.HTTPFlow):
    r = flow.request
    _w("=" * 78)
    _w(f">>> {r.method} {r.pretty_url}")
    for k, v in r.headers.items():
        _w(f"    {k}: {v}")
    if r.content:
        _w("--- request body ---")
        _w(_body(r.content))

def response(flow: http.HTTPFlow):
    r = flow.response
    _w(f"<<< {r.status_code} {r.reason}  ({flow.request.host})")
    for k, v in r.headers.items():
        _w(f"    {k}: {v}")
    _w("--- response body ---")
    _w(_body(r.content))
    _w()
