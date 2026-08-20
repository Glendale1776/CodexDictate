import Foundation

struct MultipartFormData: Sendable {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String = "CodexDictate-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    mutating func appendField(name: String, value: String) {
        data.appendUTF8("--\(boundary)\r\n")
        data.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.appendUTF8(value)
        data.appendUTF8("\r\n")
    }

    mutating func appendFile(name: String, filename: String, mimeType: String, contents: Data) {
        data.appendUTF8("--\(boundary)\r\n")
        data.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        data.appendUTF8("Content-Type: \(mimeType)\r\n\r\n")
        data.append(contents)
        data.appendUTF8("\r\n")
    }

    mutating func finalize() {
        data.appendUTF8("--\(boundary)--\r\n")
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }
}
private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(string.data(using: .utf8) ?? Data())
    }
}
