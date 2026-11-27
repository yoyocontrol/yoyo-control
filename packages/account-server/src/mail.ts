// Mail the account server sends (docs/ACCOUNT-LIB.md「邮箱和密码」): the codes of an email sign-up and a password reset.
// A `Mailer` is whatever the operator gives (`AccountConfig.mailer`); `sesMailer` sends through Amazon SES's v2 API,
// its requests signed here (AWS Signature Version 4: no SDK), with an IAM user's keys that may only send.
import { createHash, createHmac } from "node:crypto";

export interface Mail {
  to: string;
  subject: string;
  text: string;
}

export interface Mailer {
  /** Sends `mail`; throws when it was not taken (the caller says so, and the code can be asked for again). */
  send(mail: Mail): Promise<void>;
}

export interface SesOptions {
  /** The SES region, e.g. `us-east-1`. */
  region: string;
  accessKeyId: string;
  secretAccessKey: string;
  /** The sender, a verified identity of the account: `Name <no-reply@example.com>` or the bare address. */
  from: string;
  /** Tests: the network. */
  fetch?: typeof fetch;
  /** Tests: the clock (ms). */
  now?: () => number;
}

const hex = (b: Buffer) => b.toString("hex");
const sha256hex = (s: string | Buffer) => createHash("sha256").update(s).digest("hex");
const hmac = (key: Buffer | string, s: string) => createHmac("sha256", key).update(s).digest();

/**
 * The AWS Signature Version 4 headers of a request (`service` e.g. `ses`): `x-amz-date`, `x-amz-content-sha256` and
 * `authorization`, over the method, path, query, the signed headers (`host`, the two `x-amz-*`, `content-type`) and
 * the body.
 */
export function sigV4(o: { method: string; url: string; body: string; region: string; service: string; accessKeyId: string; secretAccessKey: string; contentType: string; now: number }): Record<string, string> {
  const u = new URL(o.url);
  const amzDate = new Date(o.now).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
  const day = amzDate.slice(0, 8);
  const payload = sha256hex(o.body);
  const headers: Record<string, string> = { "content-type": o.contentType, host: u.host, "x-amz-content-sha256": payload, "x-amz-date": amzDate };
  const names = Object.keys(headers).sort();
  const query = [...u.searchParams].map(([k, v]) => [encodeURIComponent(k), encodeURIComponent(v)]).sort(([a], [b]) => (a! < b! ? -1 : 1)).map(([k, v]) => `${k}=${v}`).join("&");
  const canonical = [o.method, u.pathname || "/", query, ...names.map((n) => `${n}:${headers[n]!.trim()}`), "", names.join(";"), payload].join("\n");
  const scope = `${day}/${o.region}/${o.service}/aws4_request`;
  const toSign = ["AWS4-HMAC-SHA256", amzDate, scope, sha256hex(canonical)].join("\n");
  const key = hmac(hmac(hmac(hmac(`AWS4${o.secretAccessKey}`, day), o.region), o.service), "aws4_request");
  const signature = hex(hmac(key, toSign));
  return {
    "content-type": o.contentType,
    "x-amz-date": amzDate,
    "x-amz-content-sha256": payload,
    authorization: `AWS4-HMAC-SHA256 Credential=${o.accessKeyId}/${scope}, SignedHeaders=${names.join(";")}, Signature=${signature}`,
  };
}

/** Sends through Amazon SES (v2 `SendEmail`, plain text, UTF-8). */
export function sesMailer(o: SesOptions): Mailer {
  if (!/^[a-z]{2}(-[a-z]+)+-\d$/.test(o.region)) throw new Error(`SES: ${o.region} is not a region`);
  const url = `https://email.${o.region}.amazonaws.com/v2/email/outbound-emails`;
  const f = o.fetch ?? fetch;
  const now = o.now ?? Date.now;
  return {
    async send(mail) {
      const body = JSON.stringify({
        FromEmailAddress: o.from,
        Destination: { ToAddresses: [mail.to] },
        Content: { Simple: { Subject: { Data: mail.subject, Charset: "UTF-8" }, Body: { Text: { Data: mail.text, Charset: "UTF-8" } } } },
      });
      const headers = sigV4({ method: "POST", url, body, region: o.region, service: "ses", accessKeyId: o.accessKeyId, secretAccessKey: o.secretAccessKey, contentType: "application/json", now: now() });
      const r = await f(url, { method: "POST", headers, body, signal: AbortSignal.timeout(10_000), redirect: "error" });
      if (!r.ok) {
        const text = (await r.text().catch(() => "")).slice(0, 200);
        throw new Error(`SES: HTTP ${r.status} ${text}`);
      }
    },
  };
}
