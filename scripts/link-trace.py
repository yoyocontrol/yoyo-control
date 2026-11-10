#!/usr/bin/env python3
"""Reads a uu Link session trace (docs/LINK.md「逐帧跟踪」) and prints where the frames and the time go.

    scripts/link-trace.py                      # the newest trace in ~/Library/Logs/YoyoControl/link-trace
    scripts/link-trace.py <file.jsonl> [--window 10] [--frames out.csv] [--worst 10]

Sections: the fps funnel (captured → accepted by the fps gate → encoded → sent → decoded on the phone → shown), per
window and in total; why captured pictures were not encoded (the link's queue held them back / the loop was busy);
each stage's latency (p50 / p90 / p99 / max); the send gate's reasons; the rate targets; the longest gaps between
pictures shown on the phone, with what happened to the frames around them. `--frames` writes one CSV row per frame
(the Mac's `enc` + `tx` joined with the phone's `rx` + `ph` by frame number).
"""

import argparse
import csv
import glob
import json
import os
import sys
from collections import Counter, defaultdict

TRACE_DIR = os.path.expanduser("~/Library/Logs/YoyoControl/link-trace")
KINDS = {0: "delta", 1: "key", 2: "refine", 3: "keepalive", 4: "recovery"}
SC_STATUS = {0: "complete", 1: "idle", 2: "blank", 3: "suspended", 4: "started", 5: "stopped", -1: "none"}


def pct(values, q):
    v = sorted(x for x in values if x is not None)
    if not v:
        return None
    return v[min(len(v) - 1, int(q * len(v)))]


def fmt(v, digits=1):
    return "-" if v is None else f"{v:.{digits}f}"


def dist(values):
    v = [x for x in values if x is not None]
    if not v:
        return "-"
    return f"{fmt(pct(v, .5))} / {fmt(pct(v, .9))} / {fmt(pct(v, .99))} / {fmt(max(v))}  (n {len(v)})"


def load(path):
    records = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    records.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return records


def epochs(items, key="frame"):
    """Frame numbers restart at 1 when a stream is reopened: number each run (epoch, frame)."""
    e, last, out = 0, None, []
    for r in items:
        n = r.get(key)
        if n is None:
            continue
        if last is not None and n < last - 1000:
            e += 1
        last = n
        out.append(((r.get("stream", 1), e, n), r))
    return out


def phone_host_offsets(phone_reports):
    """The phone's media clock (rx times, ms) + offset = its host clock (ph arrival, ms), per report."""
    offs = []
    for p in phone_reports:
        c = p.get("clock") or {}
        if "mediaUs" in c and "hostNowMs" in c:
            offs.append(c["hostNowMs"] - c["mediaUs"] / 1000)
    return pct(offs, .5)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file", nargs="?")
    ap.add_argument("--window", type=float, default=10, help="seconds per row of the funnel (default 10)")
    ap.add_argument("--frames", help="write the per-frame join to this CSV")
    ap.add_argument("--worst", type=int, default=8, help="how many of the longest phone gaps to show")
    a = ap.parse_args()
    path = a.file
    if not path:
        files = sorted(glob.glob(os.path.join(TRACE_DIR, "*.jsonl")), key=os.path.getmtime)
        if not files:
            sys.exit(f"no trace in {TRACE_DIR}")
        path = files[-1]
    recs = load(path)
    by = defaultdict(list)
    for r in recs:
        by[r.get("t")].append(r)
    head = (by["session"] or [{}])[0]
    t0 = min((r["at"] for r in recs if "at" in r), default=0)
    t1 = max((r["at"] for r in recs if "at" in r), default=0)
    print(f"trace {path}")
    print(f"  {head.get('device', '?')} via {head.get('path', '?')} {head.get('remote', '')}; {(t1 - t0) / 1000:.1f} s, "
          f"{len(recs)} records ({', '.join(f'{k} {len(v)}' for k, v in sorted(by.items()))})")

    cap, enc, tx, rx, ph, drops = by["cap"], by["enc"], by["tx"], by["rx"], by["ph"], by["drop"]
    off = phone_host_offsets(by["phone"])

    # --- funnel per window -------------------------------------------------------------------------------------------
    # Mac times: `at` (uptime ms). Phone records are bucketed by when their report reached the Mac (`at`).
    w = a.window * 1000
    rows = defaultdict(Counter)
    for r in cap:
        b = int((r["at"] - t0) // w)
        st = SC_STATUS.get(r.get("st"), str(r.get("st")))
        rows[b]["callbacks"] += 1
        if st == "complete":
            rows[b]["complete"] += 1
            if r.get("gated"):
                rows[b]["gated"] += 1
    for r in enc:
        b = int((r["at"] - t0) // w)
        rows[b]["encoded"] += 1
        if r.get("kind") in ("delta", "key") and r.get("want") == "live":
            rows[b]["live"] += 1
        if r.get("cause") == "held":
            rows[b]["missed_held"] += r.get("missed", 0)
        elif r.get("cause") == "busy":
            rows[b]["missed_busy"] += r.get("missed", 0)
        rows[b]["held_ms"] += r.get("heldMs", 0)
    for r in drops:
        rows[int((r["at"] - t0) // w)]["enc_drop"] += 1
    for r in tx:
        b = int((r.get("enq", r["at"]) - t0) // w)
        rows[b]["sent"] += 1
        rows[b]["acked"] += 1 if r.get("acked") is not None else 0
        rows[b]["tx_lost"] += 1 if r.get("lost") else 0
        rows[b]["wire_bytes"] += r.get("wire", 0)
    for r in rx:
        rows[int((r["at"] - t0) // w)]["rx_" + r.get("fate", "?").lower()] += 1
    for r in ph:
        b = int((r["at"] - t0) // w)
        rows[b]["ph"] += 1
        if r.get("shownMs") is not None:
            rows[b]["shown"] += 1
    secs = a.window
    print(f"\nfps funnel (per second, {a.window:g} s windows): capture callbacks complete | gated | encoded "
          f"| missed held/busy | sent | Mbps | phone delivered/skipped/lost | shown")
    total = Counter()
    for b in sorted(rows):
        c = rows[b]
        total.update(c)
        span = min(secs, max(0.001, (t1 - t0) / 1000 - b * secs))
        print(f"  {b * secs:5.0f}s  cap {c['complete'] / span:5.1f} | gated {c['gated'] / span:4.1f} | enc {c['encoded'] / span:5.1f} "
              f"| missed {c['missed_held'] / span:4.1f}/{c['missed_busy'] / span:4.1f} (held {c['held_ms'] / span / 10:4.1f}%) "
              f"| sent {c['sent'] / span:5.1f} | {c['wire_bytes'] * 8 / span / 1e6:5.1f} "
              f"| rx {c['rx_delivered'] / span:5.1f}/{c['rx_skipped'] / span:3.1f}/{c['rx_lost'] / span:3.1f} "
              f"| shown {c['shown'] / span:5.1f}")
    dur = max(0.001, (t1 - t0) / 1000)
    print(f"  total  complete {total['complete']}, gated {total['gated']}, encoded {total['encoded']} "
          f"(encoder drops {total['enc_drop']}), missed held {total['missed_held']} busy {total['missed_busy']}, "
          f"sent {total['sent']} acked {total['acked']} lost {total['tx_lost']}, phone delivered {total['rx_delivered']} "
          f"skipped {total['rx_skipped']} lost {total['rx_lost']}, shown {total['shown']} ({total['shown'] / dur:.1f}/s)")

    # --- latencies ---------------------------------------------------------------------------------------------------
    def d(r, a_, b_):
        x, y = r.get(a_), r.get(b_)
        return None if x is None or y is None else y - x

    print("\nlatency, ms (p50 / p90 / p99 / max):")
    print(f"  display → capture callback      {dist(r.get('latMs') for r in cap)}")
    gaps = []
    last = None
    for r in cap:
        if r.get("st") == 0:
            if last is not None:
                gaps.append(r["at"] - last)
            last = r["at"]
    print(f"  between complete callbacks      {dist(gaps)}")
    print(f"  callback → encode start         {dist(r.get('capWaitMs') for r in enc)}")
    print(f"  encode                          {dist(r.get('encMs') for r in enc)}")
    print(f"  hand to the link (send_frame)   {dist(r.get('sendMs') for r in enc)}")
    print(f"  callback → handed to the link   {dist(r.get('capToSentMs') for r in enc)}")
    print(f"  between encodes                 {dist(r.get('sinceLastMs') for r in enc)}")
    print(f"  queued → first datagram out     {dist(d(r, 'enq', 'firstOut') for r in tx)}")
    print(f"  queued → last datagram out      {dist(d(r, 'enq', 'lastOut') for r in tx)}")
    print(f"  last out → phone decoded (ack)  {dist(d(r, 'lastOut', 'acked') for r in tx)}")
    print(f"  phone: first shard → complete   {dist(d(r, 'firstMs', 'completeMs') for r in rx)}")
    print(f"  phone: complete → decided       {dist(d(r, 'completeMs', 'decidedMs') for r in rx)}")
    print(f"  phone: arrival → decoded        {dist(r.get('decodedMs') for r in ph)}")
    print(f"  phone: decode                   {dist(r.get('decodeMs') for r in ph)}")
    print(f"  phone: arrival → shown          {dist(r.get('shownMs') for r in ph)}")
    print(f"  capture → phone arrival (clocks) {dist(r.get('e2eMs') for r in ph)}")
    print(f"  rtt                             {dist(r.get('rttMs') for r in tx)}")

    # --- sizes, gate, rate -------------------------------------------------------------------------------------------
    print("\nframes:")
    kinds = Counter(r.get("kind") for r in enc)
    print(f"  kinds {dict(kinds)}; size KB {dist([r.get('bytes', 0) / 1000 for r in enc])}")
    print(f"  wire datagrams per frame {dist([r.get('dgrams') for r in tx])}; retransmitted shards {sum(r.get('retx', 0) for r in tx)}")
    gates = [r["gate"] for r in enc if r.get("gate")]
    if gates:
        why = Counter(g.get("why") for g in gates)
        print(f"  gate closed before {len(gates)} pictures: {dict(why)}; queued/limit {dist([(g.get('own', 0) + g.get('transport', 0)) / max(1, g.get('limit', 1)) for g in gates])}")
        print(f"  budget KB {dist([g.get('budget', 0) / 1000 for g in gates])}, estimate KB {dist([g.get('estimate', 0) / 1000 for g in gates])}")
    held = [r.get("heldMs") for r in enc if r.get("heldChecks")]
    print(f"  held back before a picture, ms {dist(held)}")
    if rx:
        print(f"  phone per frame: fec {sum(r.get('fec', 0) for r in rx)}, retx {sum(r.get('retx', 0) for r in rx)}, "
              f"nack items {sum(r.get('nacks', 0) for r in rx)} (on {sum(1 for r in rx if r.get('nacks'))} frames, "
              f"{sum(1 for r in rx if r.get('nacks') and not r.get('retx'))} with no retransmit used)")
    rates = by["rate"]
    if rates:
        print(f"\nrate targets ({len(rates)} changes): " + ", ".join(
            f"{(r['at'] - t0) / 1000:.1f}s {r['targetBps'] / 1e6:.1f}" for r in rates[:12]) + (" …" if len(rates) > 12 else ""))
    needs = Counter(r.get("what") for r in by["need"])
    if needs:
        print(f"recovery / key requests: {dict(needs)}")

    # --- the join, and the worst gaps on the phone --------------------------------------------------------------------
    join = defaultdict(dict)
    for src, items in (("enc", enc), ("tx", tx), ("rx", rx), ("ph", ph)):
        for k, r in epochs(items):
            join[k][src] = r
    shown = sorted((r["shownMs"] + r.get("arrivalMs", 0), k) for k, row in join.items() for r in [row.get("ph")]
                   if r and r.get("shownMs") is not None)
    worst = sorted(((b[0] - a_[0], a_, b) for a_, b in zip(shown, shown[1:])), reverse=True)[:a.worst]
    if worst:
        print(f"\nlongest gaps between pictures shown on the phone:")
        for gap, (ta, ka), (tb, kb) in worst:
            between = [k for k in join if k[:2] == ka[:2] and ka[2] < k[2] < kb[2]]
            fates = Counter((join[k].get("rx") or {}).get("fate", "never seen") for k in between)
            nb = join.get(kb, {})
            txb, rxb = nb.get("tx") or {}, nb.get("rx") or {}
            print(f"  {gap:6.0f} ms  frames {ka[2]}→{kb[2]}  between {dict(fates) or '-'}; next: "
                  f"{(nb.get('enc') or {}).get('kind', '?')} {txb.get('au', 0) / 1000:.0f} KB, out {fmt(d(txb, 'enq', 'lastOut'), 0)} ms, "
                  f"assembly {fmt(d(rxb, 'firstMs', 'completeMs'), 0)} ms, retx {rxb.get('retx', '-')}")

    if a.frames:
        cols = ["stream", "epoch", "frame", "seq", "kind", "bytes", "encMs", "missed", "cause", "heldMs", "capWaitMs",
                "enq", "firstOut", "lastOut", "acked", "lost", "dgrams", "retx_sent", "targetBps", "pacingBps", "queueDelayMs",
                "rttMs", "fate", "rx_first", "rx_complete", "rx_decided", "fec", "retx", "nacks", "ph_arrival", "decodedMs",
                "decodeMs", "shownMs", "e2eMs"]
        with open(a.frames, "w", newline="") as f:
            wr = csv.writer(f)
            wr.writerow(cols)
            for k in sorted(join):
                e, t_, r_, p_ = (join[k].get(s) or {} for s in ("enc", "tx", "rx", "ph"))
                host = lambda v: None if v is None or off is None else round(v + off, 3)
                wr.writerow([k[0], k[1], k[2], e.get("seq"), e.get("kind") or KINDS.get(t_.get("kind")), e.get("bytes") or t_.get("au"),
                             e.get("encMs"), e.get("missed"), e.get("cause"), e.get("heldMs"), e.get("capWaitMs"),
                             t_.get("enq"), t_.get("firstOut"), t_.get("lastOut"), t_.get("acked"), t_.get("lost"), t_.get("dgrams"),
                             t_.get("retx"), t_.get("targetBps"), t_.get("pacingBps"), t_.get("queueDelayMs"), t_.get("rttMs"),
                             r_.get("fate"), host(r_.get("firstMs")), host(r_.get("completeMs")), host(r_.get("decidedMs")),
                             r_.get("fec"), r_.get("retx"), r_.get("nacks"), p_.get("arrivalMs"), p_.get("decodedMs"),
                             p_.get("decodeMs"), p_.get("shownMs"), p_.get("e2eMs")])
        print(f"\nper-frame join: {a.frames} ({len(join)} frames; phone times on its host clock, ms)")


if __name__ == "__main__":
    main()
