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
/**
 * The AWS Signature Version 4 headers of a request (`service` e.g. `ses`): `x-amz-date`, `x-amz-content-sha256` and
 * `authorization`, over the method, path, query, the signed headers (`host`, the two `x-amz-*`, `content-type`) and
 * the body.
 */
export declare function sigV4(o: {
    method: string;
    url: string;
    body: string;
    region: string;
    service: string;
    accessKeyId: string;
    secretAccessKey: string;
    contentType: string;
    now: number;
}): Record<string, string>;
/** Sends through Amazon SES (v2 `SendEmail`, plain text, UTF-8). */
export declare function sesMailer(o: SesOptions): Mailer;
