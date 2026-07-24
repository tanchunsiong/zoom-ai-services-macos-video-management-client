import CryptoKit
import Foundation

public enum ZoomJWT {
    public static func create(credentials: APICredentials, now: Date = .now) throws -> String {
        guard credentials.isComplete else {
            throw NSError(domain: "ZScribe.Credentials", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Enter both a Zoom API key and API secret."])
        }
        let issuedAt = Int(now.timeIntervalSince1970) - 30
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let header = try encoder.encode(["alg": "HS256", "typ": "JWT"])
        let payload = try JSONSerialization.data(withJSONObject: [
            "iss": credentials.apiKey,
            "iat": issuedAt,
            "exp": issuedAt + 3600
        ], options: [.sortedKeys])
        let data = "\(base64URL(header)).\(base64URL(payload))"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(data.utf8),
            using: SymmetricKey(data: Data(credentials.apiSecret.utf8))
        )
        return "\(data).\(base64URL(Data(signature)))"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }
}
