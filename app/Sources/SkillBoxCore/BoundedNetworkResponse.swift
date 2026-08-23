import Foundation

enum BoundedNetworkResponseError: Error {
    case responseTooLarge
}

enum BoundedNetworkResponseLoader {
    static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int
    ) async throws -> (Data, URLResponse) {
        let limit = max(0, maximumBytes)
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(limit) {
            throw BoundedNetworkResponseError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1_024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else {
                throw BoundedNetworkResponseError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }
}
