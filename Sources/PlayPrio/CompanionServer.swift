import Foundation
import Network

/// A minimal HTTP/1.1 server for the iPhone remote: one request per connection, small
/// bodies, no TLS (API requests are signed instead, see `Companion`). Network I/O runs on
/// its own queue; the handler is called on the main thread.
final class CompanionServer {
    struct Request {
        let method: String
        /// Path and query exactly as sent; this is what requests are signed over.
        let target: String
        let path: String
        let query: [String: String]
        /// Header names in lower case.
        let headers: [String: String]
        let body: Data
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return Response(status: status, headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: (try? encoder.encode(value)) ?? Data("{}".utf8))
        }

        static func error(_ status: Int, _ message: String) -> Response {
            json(["error": message], status: status)
        }

        /// Serves `data` whole, or the byte range the request asks for. Safari on iOS only
        /// plays media from servers that answer range requests.
        static func file(_ data: Data, type: String, request: Request, cache: String) -> Response {
            var headers = ["Content-Type": type, "Accept-Ranges": "bytes", "Cache-Control": cache]
            guard let range = request.headers["range"] else {
                return Response(status: 200, headers: headers, body: data)
            }
            guard let bounds = byteRange(range, size: data.count) else {
                headers["Content-Range"] = "bytes */\(data.count)"
                return Response(status: 416, headers: headers)
            }
            headers["Content-Range"] = "bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(data.count)"
            return Response(status: 206, headers: headers, body: data.subdata(in: bounds.lowerBound..<bounds.upperBound + 1))
        }

        /// "bytes=a-b", "bytes=a-" or "bytes=-n" (one range only) as an inclusive range.
        static func byteRange(_ header: String, size: Int) -> ClosedRange<Int>? {
            guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
            let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let start = Int(parts[0].trimmingCharacters(in: .whitespaces))
            let end = Int(parts[1].trimmingCharacters(in: .whitespaces))
            switch (start, end) {
            case let (start?, end?) where start <= end && start < size: return start...min(end, size - 1)
            case let (start?, nil) where start < size: return start...(size - 1)
            case let (nil, suffix?) where suffix > 0: return max(0, size - suffix)...(size - 1)
            default: return nil
            }
        }
    }

    typealias Handler = (Request, @escaping (Response) -> Void) -> Void

    private static let maxRequestSize = 64 * 1024
    /// A client that doesn't finish sending its request in time is dropped.
    private static let requestTimeout: TimeInterval = 10

    private let queue = DispatchQueue(label: "local.PlayPrio.companion.server")
    private let handler: Handler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called on the main thread: nil once listening, else what went wrong.
    var onStateChange: (String?) -> Void = { _ in }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        } catch {
            report("Couldn't listen on port \(port): \(error.localizedDescription)")
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.report(nil)
            case .failed(let error), .waiting(let error):
                self?.report("Port \(port): \(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func report(_ problem: String?) {
        DispatchQueue.main.async { self.onStateChange(problem) }
    }

    // MARK: Connections (on `queue`)

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil, connection.state == .ready,
                  !self.answering.contains(id) else { return }
            connection.cancel()
        }
        receive(on: connection, buffer: Data())
    }

    /// Connections whose request is with the handler (a long poll can wait well past the timeout).
    private var answering = Set<ObjectIdentifier>()

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= Self.maxRequestSize else {
                return self.send(.error(413, "request too large"), on: connection, method: "")
            }
            switch Self.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { return connection.cancel() }
                self.receive(on: connection, buffer: buffer)
            case .invalid:
                self.send(.error(400, "bad request"), on: connection, method: "")
            case .complete(let request):
                self.answering.insert(ObjectIdentifier(connection))
                DispatchQueue.main.async {
                    var answered = false
                    self.handler(request) { response in
                        guard !answered else { return }
                        answered = true
                        self.queue.async { self.send(response, on: connection, method: request.method) }
                    }
                }
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection, method: String) {
        answering.remove(ObjectIdentifier(connection))
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        let content = Data(head.utf8) + (method == "HEAD" ? Data() : response.body)
        connection.send(content: content, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Parsing

    private enum Parsed {
        case incomplete, invalid
        case complete(Request)
    }

    private static func parse(_ buffer: Data) -> Parsed {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              requestLine[1].hasPrefix("/") else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else { return .invalid }
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        components?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return .complete(Request(method: String(requestLine[0]), target: target,
                                 path: components?.path ?? target, query: query, headers: headers,
                                 body: Data(buffer[bodyStart..<bodyStart + length])))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
