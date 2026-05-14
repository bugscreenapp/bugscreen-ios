import Foundation

/// `URLProtocol` subclass that lets tests stub HTTP responses and record outgoing
/// requests. Install on a `URLSessionConfiguration` via `protocolClasses` and
/// reset between tests.
final class StubURLProtocol: URLProtocol {

    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static var handler: Handler?

    /// All requests the SDK sent to this protocol, in order.
    static private(set) var recordedRequests: [URLRequest] = []

    /// All bodies the SDK sent. URLProtocol does not expose `httpBodyStream`-
    /// sourced bodies via `request.httpBody`, so this captures both.
    static private(set) var recordedBodies: [Data] = []

    static func reset() {
        handler = nil
        recordedRequests = []
        recordedBodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = StubURLProtocol.collectBody(from: request)
        StubURLProtocol.recordedRequests.append(request)
        StubURLProtocol.recordedBodies.append(body)

        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func collectBody(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension StubURLProtocol {

    /// Builds a `URLSession` whose only protocol class is this stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
