import CryptoKit
import Foundation

actor VideoUploadClient {
    private let baseURL: URL
    private let headers: [String: String]
    private let session: URLSession
    private let storage: URLSession
    private var cache: [String: Ready] = [:]
    private struct Target: Decodable { let url: URL; let fields: [String: String] }
    private struct Grant: Decodable { let uploadId: String; let upload: Target }
    private struct Ready: Decodable { let uploadId: String; let expiresAt: String }
    private struct Failure: Decodable { let code: String?; let message: String? }

    init(baseURL: URL, headers: [String: String], session: URLSession, storage: URLSession = URLSession(configuration: .ephemeral)) {
        self.baseURL = baseURL; self.headers = headers; self.session = session; self.storage = storage
    }

    func references(videos: [PreparedVideo], order: [ReportMediaOrder]) async throws -> String {
        var ids: [String] = []
        for video in videos {
            let checksum = try await Task.detached { try Self.checksum(video.file) }.value
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let cacheKey = "\(video.file.standardizedFileURL.path):\(checksum)"
            if let ready = cache[cacheKey], let expiry = formatter.date(from: ready.expiresAt), expiry.timeIntervalSinceNow > 5 {
                ids.append(ready.uploadId); continue
            }
            let size = try video.file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let body = try JSONSerialization.data(withJSONObject: ["sizeBytes": size, "sha256": checksum])
            let grant = try JSONDecoder().decode(Grant.self, from: await post("report-uploads", body: body))
            guard grant.upload.url.scheme == "https" else { throw BugScreenSDKError.invalidResponse }
            let boundary = "BugScreenVideo-\(UUID().uuidString)"
            let multipart = try await Task
                .detached { try Self.multipart(file: video.file, fields: grant.upload.fields, boundary: boundary) }.value
            defer { try? FileManager.default.removeItem(at: multipart) }
            var request = URLRequest(url: grant.upload.url)
            request.httpMethod = "POST"
            request.timeoutInterval = 120
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await storage.upload(for: request, fromFile: multipart)
            guard let http = response as? HTTPURLResponse,
                  (200 ... 299).contains(http.statusCode) else { throw BugScreenSDKError.invalidResponse }
            let ready = try JSONDecoder().decode(
                Ready.self,
                from: await post("report-uploads/\(grant.uploadId)/complete", body: Data("{}".utf8))
            )
            cache[cacheKey] = ready
            ids.append(ready.uploadId)
        }
        let references: [[String: Any]] = order.map { item in
            item.isVideo ? ["kind": "video", "uploadId": ids[item.index]] : ["kind": "screenshot", "index": item.index]
        }
        guard let encoded = String(data: try JSONSerialization.data(withJSONObject: references), encoding: .utf8)
        else { throw BugScreenSDKError.encodingError }
        return encoded
    }

    func clearReadyUploads() {
        cache.removeAll()
    }

    private func post(_ route: String, body: Data) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(route))
        request.httpMethod = "POST"; request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BugScreenSDKError.invalidResponse }
        if !(200 ... 299).contains(response.statusCode) {
            let error = try? JSONDecoder().decode(Failure.self, from: data)
            throw BugScreenSDKError.httpError(status: response.statusCode, code: error?.code, message: error?.message)
        }
        return data
    }

    private static func checksum(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 8192), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func multipart(file: URL, fields: [String: String], boundary: String) throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("bugscreen-video-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let target = try FileHandle(forWritingTo: output)
        defer { try? target.close() }
        do {
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                guard !key.contains("\""), !key.contains("\r"), !key.contains("\n") else { throw BugScreenSDKError.invalidResponse }
                try target
                    .write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            try target
                .write(
                    contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"video.mp4\"\r\nContent-Type: video/mp4\r\n\r\n"
                        .utf8)
                )
            let source = try FileHandle(forReadingFrom: file)
            defer { try? source.close() }
            while let data = try source.read(upToCount: 8192), !data.isEmpty {
                try target.write(contentsOf: data)
            }
            try target.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return output
        } catch { try? FileManager.default.removeItem(at: output); throw error }
    }
}
