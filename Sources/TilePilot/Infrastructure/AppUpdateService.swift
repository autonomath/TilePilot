import Foundation

enum AppUpdateServiceError: LocalizedError {
    case invalidResponse
    case badStatusCode(Int)
    case invalidReleaseURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub returned an unreadable update response."
        case .badStatusCode(let code):
            return "GitHub returned HTTP \(code)."
        case .invalidReleaseURL:
            return "GitHub returned a release without a usable page URL."
        }
    }
}

actor AppUpdateService {
    static let latestStableReleaseAPIURL = URL(string: "https://api.github.com/repos/autonomath/TilePilot/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/autonomath/TilePilot/releases")!

    private struct GitHubReleaseResponse: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: String
        let publishedAt: Date?
        let body: String?
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case body
            case draft
            case prerelease
        }
    }

    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchLatestStableRelease() async throws -> AppUpdateReleaseInfo? {
        var request = URLRequest(url: Self.latestStableReleaseAPIURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TilePilot", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppUpdateServiceError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppUpdateServiceError.badStatusCode(httpResponse.statusCode)
        }

        let decoded = try decoder.decode(GitHubReleaseResponse.self, from: data)
        guard !decoded.draft, !decoded.prerelease else {
            return nil
        }
        guard let version = normalizedAppVersionString(from: decoded.tagName) else {
            return nil
        }
        guard let releaseURL = URL(string: decoded.htmlURL) else {
            throw AppUpdateServiceError.invalidReleaseURL
        }

        return AppUpdateReleaseInfo(
            tagName: decoded.tagName,
            version: version,
            releaseName: decoded.name,
            releaseURL: releaseURL,
            publishedAt: decoded.publishedAt,
            body: decoded.body
        )
    }
}
