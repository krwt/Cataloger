import Foundation

/// OAuth2 + album-based Imgur upload, matching v1's authenticated flow
/// (uploads land in the logged-in user's own hidden "Cataloger" album,
/// rather than an anonymous, disconnected image pool).
enum ImgurUploadManager {

    enum UploadError: Error {
        case notAuthenticated
        case invalidResponse
        case serverError(String)
    }

    /// Uploads image data into the current user's Cataloger album and
    /// returns the hosted URL string. Requires the user to be logged in
    /// via `ImgurAuthManager`.
    static func upload(imageData: Data, title: String, description: String) async throws -> String {
        let auth = ImgurAuthManager.shared
        guard let accessToken = auth.accessToken else { throw UploadError.notAuthenticated }
        let albumId = try await auth.ensureAlbum()

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "https://api.imgur.com/3/upload")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        appendField("album", albumId)
        appendField("title", title)
        appendField("description", description)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"asset.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UploadError.invalidResponse }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UploadError.invalidResponse
        }

        guard http.statusCode == 200,
              let dataDict = json["data"] as? [String: Any],
              let link = dataDict["link"] as? String else {
            let message = (json["data"] as? [String: Any])?["error"] as? String ?? "Unknown Imgur error"
            throw UploadError.serverError(message)
        }

        return link
    }
}
