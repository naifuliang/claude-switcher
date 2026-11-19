import Foundation
import Network

struct GatewaySettings: Codable {
    static let profileID = UUID(uuidString: "45B87077-8D22-4FCA-AD84-3445E319AC67")!
    static let port: UInt16 = 41879
    var enabled = false
    var selectedProfileID: UUID?
    var secret = UUID().uuidString + UUID().uuidString
    static var file: URL { AppPaths.support.appendingPathComponent("gateway.json") }
    static func load() -> GatewaySettings {
        guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save() throws { try FileIO.writePrivate(JSONEncoder().encode(self), to: Self.file) }
    func proxyProfile(profiles: [Profile]) throws -> Profile {
        var profile = Profile(name: "Claude Switcher Local Gateway", kind: .gateway)
        profile.id = Self.profileID
        profile.baseURL = "http://127.0.0.1:\(Self.port)"
        profile.apiKey = secret
        profile.authScheme = .bearer
        profile.models = Array(Set(profiles.flatMap(\.models))).sorted()
        guard !profile.models.isEmpty else {
            throw SwitchError(message: L("Add or fetch at least one model before enabling seamless switching.", "启用免重启切换前，请先填写或获取至少一个模型。"))
        }
        return profile
    }
}

struct GatewayRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

enum GatewayHTTP {
    static let maxBody = 32 * 1024 * 1024
    // One request per connection. Content-Length is required for POST; ambiguous framing is rejected.
    static func parse(_ bytes: Data) throws -> GatewayRequest? {
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 65536 { throw SwitchError(message: "Headers too large") }
            return nil
        }
        guard boundary.lowerBound <= 65536, let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else {
            throw SwitchError(message: "Invalid headers")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0" else { throw SwitchError(message: "Invalid request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else { throw SwitchError(message: "Invalid header") }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { throw SwitchError(message: "Duplicate header") }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { throw SwitchError(message: "Chunked request bodies are not supported; send Content-Length") }
        let method = String(first[0])
        guard let length = Int(headers["content-length"] ?? (method == "GET" ? "0" : "-1")), length >= 0, length <= maxBody else {
            throw SwitchError(message: "Invalid or missing Content-Length")
        }
        let available = bytes.count - boundary.upperBound
        guard available >= length else { return nil }
        guard available == length else { throw SwitchError(message: "Pipelined requests are not supported") }
        return GatewayRequest(method: method, target: String(first[1]), headers: headers, body: Data(bytes[boundary.upperBound...]))
    }

    static func upstream(_ incoming: GatewayRequest, profile: Profile, secret: String) throws -> URLRequest {
        guard incoming.headers["authorization"] == "Bearer " + secret || incoming.headers["x-api-key"] == secret else {
            throw SwitchError(message: "Unauthorized local gateway request")
        }
        let path = incoming.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard (incoming.method == "POST" && ["/v1/messages", "/v1/messages/count_tokens"].contains(path)) || (incoming.method == "GET" && path == "/v1/models") else {
            throw SwitchError(message: "Unsupported gateway route")
        }
        var base = profile.kind == .gateway ? profile.normalizedBaseURL : "https://api.anthropic.com"
        if base.hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base + incoming.target), ["http", "https"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil,
              !(url.host == "127.0.0.1" && url.port == Int(GatewaySettings.port)),
              !(url.host == "localhost" && url.port == Int(GatewaySettings.port)) else {
            throw SwitchError(message: "Invalid upstream URL")
        }
        guard !profile.trimmedKey.isEmpty else { throw SwitchError(message: "Upstream credential is missing") }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = incoming.method
        request.httpBody = incoming.method == "POST" ? incoming.body : nil
        // Do not forward cookies, local credentials, host, proxy or hop-by-hop headers.
        for name in ["content-type", "accept", "anthropic-version", "anthropic-beta"] {
            if let value = incoming.headers[name] { request.setValue(value, forHTTPHeaderField: name) }
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if request.value(forHTTPHeaderField: "anthropic-version") == nil { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        if profile.kind == .gateway {
            if profile.authScheme == .bearer { request.setValue("Bearer " + profile.trimmedKey, forHTTPHeaderField: "Authorization") }
            else { request.setValue(profile.trimmedKey, forHTTPHeaderField: "x-api-key") }
        } else if profile.kind == .accountToken {
            request.setValue("Bearer " + profile.trimmedKey, forHTTPHeaderField: "Authorization")
            var beta = (request.value(forHTTPHeaderField: "anthropic-beta") ?? "").split(separator: ",").map(String.init)
            if !beta.contains("oauth-2025-04-20") { beta.append("oauth-2025-04-20") }
            request.setValue(beta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        } else { request.setValue(profile.trimmedKey, forHTTPHeaderField: "x-api-key") }
        return request
    }
}

final class LocalGateway: @unchecked Sendable {
    static let shared = LocalGateway()
    private let queue = DispatchQueue(label: "ClaudeSwitcher.gateway")
    private var listener: NWListener?
    private var connections: [UUID: GatewayConnection] = [:]

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.listener != nil { continuation.resume(); return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: GatewaySettings.port)!)
                    let listener = try NWListener(using: parameters)
                    self.listener = listener
                    var resumed = false
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .ready:
                            if !resumed { resumed = true; continuation.resume() }
                        case .failed(let error):
                            self.listener = nil
                            listener.cancel()
                            if !resumed { resumed = true; continuation.resume(throwing: error) }
                        case .cancelled:
                            if !resumed { resumed = true; continuation.resume(throwing: SwitchError(message: "Gateway startup cancelled")) }
                        default: break
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + 10) {
                        if !resumed { resumed = true; self.listener = nil; listener.cancel(); continuation.resume(throwing: SwitchError(message: "Gateway startup timed out")) }
                    }
                    listener.newConnectionHandler = { connection in
                        guard self.connections.count < 32 else { connection.cancel(); return }
                        let id = UUID()
                        let handler = GatewayConnection(connection: connection, queue: self.queue) { self.connections[id] = nil }
                        self.connections[id] = handler
                        handler.start()
                    }
                    listener.start(queue: self.queue)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in Array(self.connections.values) { connection.finish() }
        }
    }
}

private final class GatewayConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let onFinish: () -> Void
    var buffer = Data()
    var session: URLSession?
    var task: URLSessionDataTask?
    var finished = false
    var sentHeaders = false
    var timer: DispatchWorkItem?
    var queuedBytes = 0
    var suspended = false

    init(connection: NWConnection, queue: DispatchQueue, onFinish: @escaping () -> Void) {
        self.connection = connection; self.queue = queue; self.onFinish = onFinish
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish() }
            if case .cancelled = state { self?.finish() }
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { [weak self] in self?.finish() }
        timer = timeout
        queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        receive()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if let data { self.buffer.append(data) }
            if self.buffer.count > GatewayHTTP.maxBody + 65536 { self.fail(413, "Request too large"); return }
            do {
                if let request = try GatewayHTTP.parse(self.buffer) {
                    self.timer?.cancel()
                    let settings = GatewaySettings.load()
                    guard settings.enabled,
                          let profile = ProfileStore.load().first(where: { $0.id == settings.selectedProfileID }) else {
                        self.fail(503, "No upstream account selected"); return
                    }
                    // Snapshot the route once, so an in-flight stream stays on its original account.
                    guard request.headers["authorization"] == "Bearer " + settings.secret || request.headers["x-api-key"] == settings.secret else {
                        self.fail(401, "Unauthorized local gateway request"); return
                    }
                    let upstream = try GatewayHTTP.upstream(request, profile: profile, secret: settings.secret)
                    self.buffer.removeAll()
                    let config = URLSessionConfiguration.ephemeral
                    config.httpShouldSetCookies = false
                    config.urlCache = nil
                    config.timeoutIntervalForResource = 1800
                    let delegateQueue = OperationQueue()
                    delegateQueue.maxConcurrentOperationCount = 1
                    delegateQueue.underlyingQueue = self.queue
                    let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
                    self.session = session
                    self.task = session.dataTask(with: upstream)
                    self.task?.resume()
                    return
                }
                if complete || error != nil { self.finish() } else { self.receive() }
            } catch { self.fail(400, error.localizedDescription) }
        }
    }
    func fail(_ status: Int, _ message: String) {
        guard !finished else { return }
        let body = (try? JSONSerialization.data(withJSONObject: ["type":"error", "error":["type":"gateway_error","message":message]])) ?? Data()
        let head = "HTTP/1.1 \(status) Error\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a provider credential to a redirect target.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, !finished else { completionHandler(.cancel); return }
        var head = "HTTP/1.1 \(response.statusCode) Response\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n"
        for name in ["Content-Type", "Retry-After", "Request-Id", "X-Request-Id"] {
            if let value = response.value(forHTTPHeaderField: name), !value.contains("\r"), !value.contains("\n") { head += "\(name): \(value)\r\n" }
        }
        head += "\r\n"
        sentHeaders = true
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in if error != nil { self?.finish() } })
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        let chunk = Data(String(data.count, radix: 16).utf8) + Data("\r\n".utf8) + data + Data("\r\n".utf8)
        queuedBytes += chunk.count
        if queuedBytes > 1024 * 1024 && !suspended { suspended = true; dataTask.suspend() }
        connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queuedBytes -= chunk.count
            if error != nil { self.finish(); return }
            if self.suspended && self.queuedBytes < 512 * 1024 { self.suspended = false; self.task?.resume() }
        })
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if error != nil {
            if sentHeaders { finish() } else { fail(502, "Could not reach the selected provider") }
            return
        }
        connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
    func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        task?.cancel()
        session?.invalidateAndCancel()
        connection.cancel()
        onFinish()
    }
}
