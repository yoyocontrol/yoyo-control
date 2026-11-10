import assert from "node:assert/strict";
import { test } from "node:test";
import { PairingLinkError, parsePairingLink } from "../src/pairing.js";

const fp = "ab".repeat(32);

test("the whole URL, the fragment with or without #", () => {
  const url = `https://app.example.com/pair#v=1&id=srv-1&n=Alex%E2%80%99s%20Mac&fp=sha256:${fp}&c=c0de-_x`;
  const want = { serverId: "srv-1", name: "Alex’s Mac", fingerprint: `sha256:${fp}`, code: "c0de-_x" };
  assert.deepEqual(parsePairingLink(url), want);
  assert.deepEqual(parsePairingLink(new URL(url)), want);
  assert.deepEqual(parsePairingLink(new URL(url).hash), want);
  assert.deepEqual(parsePairingLink(new URL(url).hash.slice(1)), want);
});

test("fingerprints in other spellings are normalized; a name is cleaned and defaults to Mac", () => {
  const upper = fp.toUpperCase().match(/../g)!.join(":");
  const l = parsePairingLink(`#v=1&id=s&fp=SHA256:${upper}&c=x&n=%0AStudio%00`);
  assert.equal(l.fingerprint, `sha256:${fp}`);
  assert.equal(l.name, "Studio");
  assert.equal(parsePairingLink(`#v=1&id=s&fp=${fp}&c=x`).name, "Mac");
});

test("incomplete, malformed or newer links are refused", () => {
  for (const bad of ["", "#v=1&id=s&c=x", `#v=1&id=s&fp=sha256:${fp}`, `#v=1&fp=sha256:${fp}&c=x`, "#v=1&id=s&fp=sha256:abc&c=x", "https://app.example.com/pair"]) {
    assert.throws(() => parsePairingLink(bad), PairingLinkError, bad);
  }
  assert.throws(() => parsePairingLink(`#v=2&id=s&fp=sha256:${fp}&c=x`), /newer version/);
});
