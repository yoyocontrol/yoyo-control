/** A refused request: its HTTP status, the server's `error` text, and its JSON body (e.g. a 409's `code`). */
export class RequestError extends Error {
    status;
    body;
    constructor(status, message, body) {
        super(message);
        this.status = status;
        this.body = body;
    }
}
/** A response that isn't ok as a RequestError (its JSON `error`, else `HTTP <status>`). */
export async function requestError(res) {
    let body;
    try {
        body = (await res.json());
    }
    catch {
        /* not JSON */
    }
    return new RequestError(res.status, typeof body?.error === "string" ? body.error : `HTTP ${res.status}`, body);
}
/** The global fetch with a path prefix and same-origin credentials (a page served by the screen's own server). */
export function sameOriginTransport(prefix = "", extraHeaders = () => ({})) {
    return {
        fetch: (path, init) => fetch(`${prefix}${path}`, {
            credentials: "same-origin",
            ...init,
            headers: { ...init.headers, ...extraHeaders(path) },
        }),
    };
}
