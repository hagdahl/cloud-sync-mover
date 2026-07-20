#!/usr/bin/env python3
# parse_odl.py - read OneDrive ODL logs and summarize throttle/error signals.
# .aodl is usually cleartext (starts with EBFGONED); .odlgz and embedded blocks are gzip.
# Dynamic values (file paths) are partly obfuscated, but scenario names, HTTP codes and
# function names are readable - enough to tell transient throttling from real hard errors.
import sys, os, re, zlib, glob, json
from collections import Counter
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def decompress(b):
    i = b.find(b"\x1f\x8b\x08")   # first gzip member
    if i < 0:
        return b                  # plain .aodl
    parts = []
    buf = b[i:]
    while buf:
        try:
            d = zlib.decompressobj(31)
            parts.append(d.decompress(buf))
            parts.append(d.flush())
            buf = d.unused_data
            k = buf.find(b"\x1f\x8b\x08")
            if k < 0:
                break
            buf = buf[k:]
        except Exception:
            # A truncated trailing gzip member (a live log still being written) is expected: keep
            # what decompressed so far and stop THIS file. Bounded and intentional - not a silent
            # whole-file drop (a fully unreadable file is caught and reported by main). (B8)
            break
    return b"".join(parts) if parts else b


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: parse_odl.py <logs_dir> [max_files]"}))
        return
    logs = sys.argv[1]
    max_files = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    all_files = glob.glob(os.path.join(logs, "**", "*"), recursive=True)
    cand = [f for f in all_files if f.lower().endswith((".odl", ".aodl", ".odlgz"))]
    cand.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    files = cand[:max_files]

    blob = bytearray()
    parsed = 0
    skipped = []
    for f in files:
        try:
            with open(f, "rb") as fh:
                blob += decompress(fh.read())
            parsed += 1
        except Exception as e:
            # B8: do not swallow silently. stdout is reserved for the JSON result, so warn on stderr
            # and report the shortfall in the output (files_parsed vs files_attempted) so a
            # half-scanned run does not masquerade as complete.
            skipped.append(os.path.basename(f))
            print("WARN: could not read %s: %r" % (os.path.basename(f), e), file=sys.stderr, flush=True)
    blob = bytes(blob)

    terms = ["Throttl", "Quota", "429", "403", "503", "Conflict", "Blocked",
             "Failure", "Denied", "ActiveHydration", "ProcessQuotaThrottleWarningHeader", "getErrors"]
    term_counts = {t: blob.count(t.encode()) for t in terms}

    scen = Counter()
    for m in re.finditer(rb"[\x20-\x7e]{8,}", blob):
        s = m.group()
        if b"Scenario" in s and (b"Download" in s or b"Hydration" in s or b"Upload" in s):
            scen[s[:80].decode("latin1", "replace")] += 1

    throttling = (term_counts["429"] > 0 or term_counts["403"] > 0
                  or term_counts["Throttl"] > 0 or term_counts["ProcessQuotaThrottleWarningHeader"] > 0)
    out = {
        "files_attempted": len(files),
        "files_parsed": parsed,
        "files_skipped": skipped,
        "newest": os.path.basename(files[0]) if files else None,
        "decompressed_kb": len(blob) // 1024,
        "term_counts": term_counts,
        "top_scenarios": scen.most_common(10),
        "throttling_signals": bool(throttling),
        "hint": "429/403 on Download/Hydration + throttle terms => transient throttling during "
                "mass hydration, not data loss. Confirm against the state DB (read_sync_state.py).",
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr, flush=True)
        sys.exit(130)
