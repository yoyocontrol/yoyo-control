export declare const PASSWORD_MIN = 8;
export declare const PASSWORD_MAX = 256;
/** `scrypt$N$r$p$<salt>$<hash>` (base64url). */
export declare function hashPassword(password: string): Promise<string>;
/** Whether `password` is the one `stored` was made of (a malformed `stored`: no). */
export declare function verifyPassword(password: string, stored: string): Promise<boolean>;
export declare function decoyHash(): Promise<string>;
/** A password that may be set: 8–256 characters. */
export declare function passwordProblem(password: unknown): string | null;
/** The email as it is kept and compared: trimmed, lower case; null when it is not an address. */
export declare function normalizeEmail(raw: unknown): string | null;
/** A one-time code: 6 digits. */
export declare function newCode(): string;
/** How a code is kept: never the code itself. */
export declare function codeHash(email: string, purpose: string, code: string): string;
export type CodePurpose = "register" | "reset";
/** The mail of a code, in `locale`'s language (zh* → Simplified Chinese, else English). `existing`: a sign-up for an
 *  email that has an account already (it says so instead of a code). */
export declare function codeMail(o: {
    purpose: CodePurpose;
    code: string | null;
    serverName: string;
    locale: string | undefined;
    minutes: number;
}): {
    subject: string;
    text: string;
};
