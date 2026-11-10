import Foundation
import Synchronization
import YoyoClipboard
import YoyoCore

/// One screen stream connection (`GET /stream`, docs/PROTOCOL.md) on its own data-delegate URLSession, so bytes arrive as
/// they come (`URLSession.bytes` would hand them over one by one). Its parts (video pictures, cursor and status updates)
/// go to `onPart`; acks for it go out on the same session (`send`), so they ride the same connection. Callbacks run on
/// a private serial queue; after `cancel()` none fire any more. The server's certificate is checked as the backend's
/// `trust` says (a custom one: the backend's own check, and redirects are not followed). The sound stream
/// (`ScreenAudio`, `GET /audio`) is one too: the same framing, its format in the response's headers (`onHead`).
final class ScreenStream: NSObject, URLSessionDataDelegate, Sendable {
    /// The stream is open; its `X-Stream-Codec` (nil: none).
    typealias OnOpen = @Sendable (String?) -> Void
    typealias OnPart = @Sendable (ScreenStreamPart) -> Void
    /// nil = the server ended the stream; else why it failed.
    typealias OnEnd = @Sendable (Error?) -> Void
    /// The stream's own response headers (a 2xx one), names lowercased, just before `onOpen`.
    typealias OnHead = @Sendable ([String: String]) -> Void

    private struct State {
        var assembler = StreamPartAssembler()
        var opened = false
        var failure: Error?
        var done = false
        /// The stream's own task (acks are other tasks on the same session).
        var task: Int?
    }

    private let request: URLRequest
    private let onOpen: OnOpen
    private let onPart: OnPart
    private let onEnd: OnEnd
    private let onHead: OnHead?
    private let stats: ScreenStreamStats?
    /// How the server's certificate is checked.
    private let trust: YoyoTrust
    private let state = Mutex(State())
    private let session = Mutex<URLSession?>(nil)

    init(request: URLRequest, stats: ScreenStreamStats? = nil, trust: YoyoTrust = .system,
         onHead: OnHead? = nil, onOpen: @escaping OnOpen, onPart: @escaping OnPart, onEnd: @escaping OnEnd) {
        self.request = request
        self.onHead = onHead
        self.stats = stats
        self.trust = trust
        self.onOpen = onOpen
        self.onPart = onPart
        self.onEnd = onEnd
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = 24 * 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ca.sarria.yoyocontrol.screen-stream"
        queue.qualityOfService = .userInteractive
        let s = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        session.withLock { $0 = s }
        let task = s.dataTask(with: request)
        state.withLock { $0.task = task.taskIdentifier }
        task.resume()
    }

    func cancel() {
        state.withLock { $0.done = true }
        // the session holds its delegate until invalidated
        session.withLock { $0?.invalidateAndCancel(); $0 = nil }
    }

    typealias Reply = ScreenStreamReply

    /// Sends a small request (an ack) on this stream's session; `done` gets how it went.
    func send(_ request: URLRequest, done: @escaping @Sendable (Reply) -> Void) {
        guard let s = session.withLock({ $0 }) else { done(Reply()); return }
        let task = s.dataTask(with: request) { data, response, error in
            if let error { done(Reply(error: error as? URLError ?? URLError(.unknown))); return }
            done(Reply(status: (response as? HTTPURLResponse)?.statusCode, body: data))
        }
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    // MARK: Trust (the backend's)

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (d, c) = trust.disposition(challenge)
        completionHandler(d, c)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (d, c) = trust.disposition(challenge)
        completionHandler(d, c)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // a server checked by the backend itself never redirects: a redirect is not followed
        completionHandler(trust.followsRedirects ? request : nil)
    }

    // MARK: URLSessionDataDelegate

    /// Called once for the stream, and again for every part when URLSession splits a multipart stream itself (see
    /// `StreamPartAssembler`): those later calls are parts, not failures.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let headers = ScreenPartHeaders { http?.value(forHTTPHeaderField: $0) }
        let (parts, open, codec, failed) = state.withLock { s -> ([ScreenStreamPart], Bool, String?, Bool) in
            guard dataTask.taskIdentifier == s.task else { return ([], false, nil, false) }
            do {
                let parts = try s.assembler.receive(status: http?.statusCode ?? 200,
                                                    contentType: headers.contentType ?? response.mimeType,
                                                    expectedLength: response.expectedContentLength,
                                                    headers: headers)
                let open = !s.opened && !s.done
                s.opened = true
                return (s.done ? [] : parts, open, s.assembler.streamCodec, false)
            } catch {
                s.failure = error
                return ([], false, nil, true)
            }
        }
        if failed { completionHandler(.cancel); return }
        completionHandler(.allow)
        if open, let onHead {
            var fields: [String: String] = [:]
            for (name, value) in http?.allHeaderFields ?? [:] {
                if let name = name as? String, let value = value as? String { fields[name.lowercased()] = value }
            }
            onHead(fields)
        }
        if open { onOpen(codec) }
        for p in parts { onPart(p) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let parts = state.withLock { s -> [ScreenStreamPart] in
            guard dataTask.taskIdentifier == s.task, !s.done, s.opened else { return [] }
            return s.assembler.feed(data)
        }
        stats?.received(bytes: data.count)
        for p in parts { onPart(p) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (fire, failure, last) = state.withLock { s -> (Bool, Error?, [ScreenStreamPart]) in
            // an ack finishing is not the stream ending
            guard task.taskIdentifier == s.task else { return (false, nil, []) }
            let fire = !s.done
            let last = fire && s.failure == nil ? s.assembler.finish() : []
            s.done = true
            return (fire, s.failure ?? error, last)
        }
        guard task.taskIdentifier == state.withLock({ $0.task }) else { return }
        for p in last { onPart(p) }
        session.finishTasksAndInvalidate()
        self.session.withLock { $0 = nil }
        if fire { onEnd(failure) }
    }
}

extension Duration {
    /// This duration in (fractional) milliseconds.
    var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}

/// How a request sent on a stream's session (an ack) went.
public struct ScreenStreamReply: Sendable {
    /// The HTTP status; nil when it failed on the way or the stream is gone.
    public var status: Int?
    public var body: Data?
    /// Why it failed on the way (nil: answered, or the stream is gone).
    public var error: URLError?

    public init(status: Int? = nil, body: Data? = nil, error: URLError? = nil) {
        self.status = status
        self.body = body
        self.error = error
    }

        /// It failed on the way (a timeout, a network error, a proxy not reaching the Mac), not with an answer and
        /// not cancelled (`ScreenNetSampler.isNetworkFailure`).
        var isNetworkFailure: Bool { ScreenNetSampler.isNetworkFailure(status: status, body: body, error: error) }

        /// An ack answer's `net` (nil: none, or not a success). Never fails the ack.
        var netQuality: ScreenNetQuality? {
            guard let status, (200..<300).contains(status) else { return nil }
            return ScreenNetQuality(ackResponse: body)
        }
    }
