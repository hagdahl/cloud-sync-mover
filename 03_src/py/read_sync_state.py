#!/usr/bin/env python3
# read_sync_state.py - read OneDrive SyncEngine/OCSI SQLite state (READ-ONLY) and summarize.
# Input: a snapshot directory containing <account>/SyncEngineDatabase.db (+ OCSI.db) copies.
# Output: JSON summary to stdout. Never opens live DBs; operate on copies only (see wrapper).
import sys, os, json, sqlite3
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def q(cur, sql):
    # Returns the rows on success, or None when the query itself failed (missing table / schema
    # drift / unreadable DB). None means "could not read", NOT "zero rows" - the caller must fail
    # closed on None rather than treat it as 0 (A4 / ADR-012).
    try:
        return cur.execute(sql).fetchall()
    except Exception:
        return None


def read_account(db_dir):
    out = {}
    se = os.path.join(db_dir, "SyncEngineDatabase.db")
    if os.path.exists(se):
        try:
            con = sqlite3.connect(se, timeout=30)
            cur = con.cursor()
            r = q(cur, "SELECT COUNT(*) FROM od_ClientFile_Records")
            out["files"] = r[0][0] if r else None
            fs = q(cur, "SELECT fileStatus, COUNT(*) FROM od_ClientFile_Records GROUP BY fileStatus ORDER BY 2 DESC")
            out["fileStatus_dist"] = {str(a): b for a, b in fs} if fs else None
            hs = q(cur, "SELECT COUNT(*) FROM od_ClientFile_Records WHERE holdStateReason IS NOT NULL")
            out["files_in_hold_state"] = hs[0][0] if hs else None
            oc = q(cur, "SELECT resultCode, COUNT(*) FROM od_ServiceOperationHistory GROUP BY resultCode ORDER BY 2 DESC")
            out["op_result_codes"] = {str(a): b for a, b in oc} if oc else None
            th = q(cur, "SELECT reason, COUNT(*) FROM od_ThrottleHistory GROUP BY reason")
            out["throttle_events"] = {str(a): b for a, b in th} if th else None
            for t in ("od_CreateAddedFolderFailures", "od_UnrealizedFile_Records", "od_ClientFilePostponedChange_Records"):
                rr = q(cur, "SELECT COUNT(*) FROM %s" % t)
                out[t] = rr[0][0] if rr else None
            con.close()
        except Exception as e:
            out["syncengine_error"] = repr(e)
    oc_db = os.path.join(db_dir, "OCSI.db")
    if os.path.exists(oc_db):
        try:
            con = sqlite3.connect(oc_db, timeout=30)
            cur = con.cursor()
            r = q(cur, "SELECT COUNT(*) FROM ocsi_property_records WHERE conflictJson <> '' AND conflictJson IS NOT NULL")
            out["conflicts"] = r[0][0] if r else None
            con.close()
        except Exception as e:
            out["ocsi_error"] = repr(e)
    codes = out.get("op_result_codes") or {}
    throttled = any(k in ("429", "403", "503") for k in codes) or bool(out.get("throttle_events"))
    hard = (out.get("conflicts") or 0) or (out.get("files_in_hold_state") or 0) \
        or (out.get("od_CreateAddedFolderFailures") or 0) or (out.get("od_UnrealizedFile_Records") or 0)
    # Fail closed (A4 / ADR-012): "clean_state" must rest on a POSITIVE read, not on the mere
    # absence of signals. If the SyncEngine DB is missing or a count query failed (out["files"] is
    # None), or either DB raised (syncengine_error / ocsi_error), we could not have SEEN hard errors
    # even if they exist -> report "unknown", never "clean_state".
    read_error = ("syncengine_error" in out) or ("ocsi_error" in out)
    se_readable = os.path.exists(se) and (out.get("files") is not None)
    if read_error or not se_readable:
        out["verdict"] = "unknown"
    elif hard:
        out["verdict"] = "hard_errors_present"
    else:
        out["verdict"] = "clean_state"
    out["throttling_signals"] = bool(throttled)
    return out


def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "usage: read_sync_state.py <snapshot_dir>"}))
        return
    root = sys.argv[1]
    accounts = []
    if os.path.isdir(root):
        for name in sorted(os.listdir(root)):
            d = os.path.join(root, name)
            if os.path.isdir(d):
                a = read_account(d)
                a["account"] = name
                accounts.append(a)
    print(json.dumps({"accounts": accounts}, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr, flush=True)
        sys.exit(130)
