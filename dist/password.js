// Email and password (docs/ACCOUNT-LIB.md「邮箱和密码」): the pieces the account server's routes use — the password's
// hash (scrypt, salted, slow on purpose), the email as it is kept, the one-time codes mailed for a sign-up and a reset,
// and those mails' words.
import { randomBytes, randomInt, scrypt, timingSafeEqual, createHash } from "node:crypto";
/** scrypt's cost: 2^15, r 8, p 1 (32 MiB, some 50–100 ms here) — what OWASP names for scrypt. */
const N = 1 << 15;
const R = 8;
const P = 1;
const KEYLEN = 32;
const MAXMEM = 64 * 1024 * 1024;
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 256;
function scryptAsync(password, salt, n, r, p) {
    return new Promise((resolve, reject) => scrypt(password.normalize("NFKC"), salt, KEYLEN, { N: n, r, p, maxmem: MAXMEM }, (e, k) => (e ? reject(e) : resolve(k))));
}
/** `scrypt$N$r$p$<salt>$<hash>` (base64url). */
export async function hashPassword(password) {
    const salt = randomBytes(16);
    const k = await scryptAsync(password, salt, N, R, P);
    return `scrypt$${N}$${R}$${P}$${salt.toString("base64url")}$${k.toString("base64url")}`;
}
/** Whether `password` is the one `stored` was made of (a malformed `stored`: no). */
export async function verifyPassword(password, stored) {
    const m = /^scrypt\$(\d+)\$(\d+)\$(\d+)\$([A-Za-z0-9_-]+)\$([A-Za-z0-9_-]+)$/.exec(stored);
    if (!m)
        return false;
    const [n, r, p] = [Number(m[1]), Number(m[2]), Number(m[3])];
    if (n > 1 << 20 || r > 32 || p > 16)
        return false;
    const want = Buffer.from(m[5], "base64url");
    const got = await scryptAsync(password, Buffer.from(m[4], "base64url"), n, r, p);
    return got.length === want.length && timingSafeEqual(got, want);
}
/** A hash made once, verified against when there is no such login (the answer takes as long either way). */
let decoy = null;
export function decoyHash() {
    decoy ??= hashPassword(randomBytes(16).toString("hex"));
    return decoy;
}
/** A password that may be set: 8–256 characters. */
export function passwordProblem(password) {
    if (typeof password !== "string")
        return "a password";
    const n = [...password].length;
    if (n < PASSWORD_MIN)
        return `at least ${PASSWORD_MIN} characters`;
    if (n > PASSWORD_MAX)
        return `at most ${PASSWORD_MAX} characters`;
    return null;
}
/** The email as it is kept and compared: trimmed, lower case; null when it is not an address. */
export function normalizeEmail(raw) {
    if (typeof raw !== "string")
        return null;
    const e = raw.trim().toLowerCase();
    if (e.length > 254 || !/^[^\s@<>()",;:\\[\]]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$/.test(e))
        return null;
    return e;
}
/** A one-time code: 6 digits. */
export function newCode() {
    return String(randomInt(0, 1_000_000)).padStart(6, "0");
}
/** How a code is kept: never the code itself. */
export function codeHash(email, purpose, code) {
    return createHash("sha256").update(`${purpose}\n${email}\n${code}`).digest("base64url");
}
/** The mail of a code, in `locale`'s language (zh* → Simplified Chinese, else English). `existing`: a sign-up for an
 *  email that has an account already (it says so instead of a code). */
export function codeMail(o) {
    const zh = (o.locale ?? "").toLowerCase().startsWith("zh");
    const name = o.serverName;
    if (o.code === null) {
        return zh
            ? { subject: `${name}：这个邮箱已经注册过`, text: `有人（可能就是你）想用这个邮箱注册 ${name}，但它已经有账号了。\n\n直接登录就行；忘了密码，在登录页点「忘记密码」。\n\n不是你本人操作的话，不用理会这封邮件。\n` }
            : { subject: `${name}: this email already has an account`, text: `Someone (probably you) tried to sign up for ${name} with this email, but it already has an account.\n\nJust sign in; if you forgot the password, choose "Forgot password" on the sign-in page.\n\nIf this wasn't you, you can ignore this email.\n` };
    }
    if (o.purpose === "register") {
        return zh
            ? { subject: `${name} 验证码：${o.code}`, text: `你的 ${name} 注册验证码是：\n\n    ${o.code}\n\n${o.minutes} 分钟内有效。不是你本人操作的话，不用理会这封邮件。\n` }
            : { subject: `Your ${name} code: ${o.code}`, text: `Your code to sign up for ${name}:\n\n    ${o.code}\n\nIt works for ${o.minutes} minutes. If this wasn't you, you can ignore this email.\n` };
    }
    return zh
        ? { subject: `${name} 重设密码验证码：${o.code}`, text: `你在重设 ${name} 的密码，验证码是：\n\n    ${o.code}\n\n${o.minutes} 分钟内有效。不是你本人操作的话，不用理会这封邮件，你的密码不会变。\n` }
        : { subject: `Your ${name} password reset code: ${o.code}`, text: `Your code to reset your ${name} password:\n\n    ${o.code}\n\nIt works for ${o.minutes} minutes. If this wasn't you, you can ignore this email; your password stays as it is.\n` };
}
