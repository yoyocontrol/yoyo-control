/** `/stream`'s JSON body (what `VideoStream` posts) as a link's `video.open` query: every field but `ack`, in order. */
export function linkStreamQuery(body) {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(body)) {
        if (k === "ack" || v === undefined || v === null)
            continue;
        q.set(k, String(v));
    }
    return q.toString();
}
