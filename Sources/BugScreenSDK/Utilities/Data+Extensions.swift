import Foundation

/// Extensions to Foundation's Data type for multipart form-data encoding.
///
/// These utilities are used internally by the API client to construct
/// multipart/form-data HTTP request bodies.
extension Data {

    /// Appends a string to the Data using UTF-8 encoding.
    ///
    /// This is a convenience method for building multipart form-data requests,
    /// where we need to append strings (headers, boundaries) to binary data.
    ///
    /// - Parameter string: The string to append
    ///
    /// Example:
    /// ```swift
    /// var body = Data()
    /// body.append("--boundary\r\n")
    /// body.append("Content-Disposition: form-data; name=\"field\"\r\n\r\n")
    /// body.append("value\r\n")
    /// ```
    internal mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
