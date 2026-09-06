import CryptoKit
import Foundation

public enum DefaultCommunityMediaSearchSources {
    public static func make() -> [any CommunityMediaSearchSource] {
        [
            YTDLPCommunityMediaSearchSource(),
            BilibiliCommunityMediaSearchSource(),
            SogouWeChatCommunityMediaSearchSource(),
        ]
    }
}

public struct SogouWeChatCommunityMediaSearchSource: CommunityMediaSearchSource, Sendable {
    public let platform: DiscoveryCommunityPlatform = .wechat

    private let session: URLSession
    private let endpoint: URL

    public init() {
        self.init(
            session: URLSession(configuration: SilentCommunityURLSessionConfiguration.make()),
            endpoint: URL(string: "https://weixin.sogou.com/weixin")!
        )
    }

    public init(session: URLSession, endpoint: URL) {
        self.session = session
        self.endpoint = endpoint
    }

    public func search(query: String, limit: Int) async throws -> [CommunityMediaSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillDiscoveryError.emptyQuery }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "type", value: "2"),
            .init(name: "query", value: trimmed),
            .init(name: "page", value: "1"),
            .init(name: "ie", value: "utf8"),
        ]
        guard let searchURL = components?.url else { throw SkillDiscoveryError.invalidResponse }

        var request = URLRequest(url: searchURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DiscoveryNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: 1 * 1_024 * 1_024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SkillDiscoveryError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw SkillDiscoveryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SkillDiscoveryError.requestFailed(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else {
            throw CommunityMediaSourceError.unreadableOutput(.wechat)
        }
        return try Self.parse(html: html, searchURL: searchURL, limit: min(max(limit, 1), 10))
    }

    static func parse(html: String, searchURL: URL, limit: Int) throws -> [CommunityMediaSearchItem] {
        let lowered = html.lowercased()
        if ["antispider", "验证码", "安全验证", "异常访问", "访问过于频繁"].contains(where: lowered.contains) {
            throw CommunityMediaSourceError.blocked(.wechat)
        }

        let cards = HTMLTextExtraction.captures(
            pattern: #"<li\b[^>]*id=[\"']sogou_vr_11002601_box_[^\"']+[\"'][^>]*>(.*?)</li>"#,
            in: html,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        if cards.isEmpty {
            if lowered.contains("没有找到相关的微信文章") || lowered.contains("no-result") || lowered.contains("no_result") {
                return []
            }
            throw CommunityMediaSourceError.unreadableOutput(.wechat)
        }

        let selectedCards = Array(cards.prefix(limit))
        let items: [CommunityMediaSearchItem] = selectedCards.enumerated().compactMap { index, card in
            guard let rawTitle = HTMLTextExtraction.firstCapture(
                pattern: #"<h3\b[^>]*>.*?<a\b[^>]*>(.*?)</a>.*?</h3>"#,
                in: card,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { return nil }
            let title = HTMLTextExtraction.plainText(rawTitle)
            guard !title.isEmpty else { return nil }

            let summary = HTMLTextExtraction.firstCapture(
                pattern: #"<p\b[^>]*class=[\"'][^\"']*\btxt-info\b[^\"']*[\"'][^>]*>(.*?)</p>"#,
                in: card,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(HTMLTextExtraction.plainText)
            let author = HTMLTextExtraction.firstCapture(
                pattern: #"<span\b[^>]*class=[\"'][^\"']*\ball-time-y2\b[^\"']*[\"'][^>]*>(.*?)</span>"#,
                in: card,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ).map(HTMLTextExtraction.plainText)
            let timestamp = HTMLTextExtraction.firstCapture(
                pattern: #"timeConvert\([\"'](\d{9,12})[\"']\)"#,
                in: card,
                options: [.caseInsensitive]
            ).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            let identity = [title, author ?? "", String(index)].joined(separator: "|")

            return CommunityMediaSearchItem(
                id: "wechat/\(String(identity.prefix(280)))",
                platform: .wechat,
                author: author,
                title: title,
                summary: summary?.isEmpty == false ? summary : nil,
                url: searchURL,
                publishedAt: timestamp
            )
        }
        guard items.count == selectedCards.count else {
            throw CommunityMediaSourceError.unreadableOutput(.wechat)
        }
        return items
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Safari/537.36"
}

public enum BilibiliWBISigner {
    private static let mixinKeyTable = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    public static func signedQuery(
        parameters: [String: String],
        imageKey: String,
        subKey: String,
        timestamp: Int64
    ) -> String {
        let rawKey = Array(imageKey + subKey)
        let mixinKey = String(mixinKeyTable.compactMap { rawKey.indices.contains($0) ? rawKey[$0] : nil }.prefix(32))
        var values = parameters
        values["wts"] = String(timestamp)
        let query = values.keys.sorted().map { key in
            let cleaned = values[key, default: ""].filter { !"!'()*".contains($0) }
            return "\(percentEncode(key))=\(percentEncode(cleaned))"
        }.joined(separator: "&")
        let digest = Insecure.MD5.hash(data: Data((query + mixinKey).utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(query)&w_rid=\(digest)"
    }

    private static func percentEncode(_ value: String) -> String {
        value.utf8.map { byte -> String in
            let allowed = (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || [45, 46, 95, 126].contains(byte)
            return allowed ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }
}

public struct BilibiliCommunityMediaSearchSource: CommunityMediaSearchSource, Sendable {
    public let platform: DiscoveryCommunityPlatform = .bilibili

    private struct NavigationData: Decodable {
        struct WBIImage: Decodable {
            var imageURL: String
            var subURL: String

            enum CodingKeys: String, CodingKey {
                case imageURL = "img_url"
                case subURL = "sub_url"
            }
        }

        var wbiImage: WBIImage

        enum CodingKeys: String, CodingKey {
            case wbiImage = "wbi_img"
        }
    }

    private struct SearchData: Decodable {
        var result: [Video]
    }

    private struct Video: Decodable {
        var author: String?
        var bvid: String?
        var title: String?
        var description: String?
        var play: Int?
        var publishedAt: Int?

        enum CodingKeys: String, CodingKey {
            case author, bvid, title, description, play
            case publishedAt = "pubdate"
        }
    }

    private struct Envelope<Value: Decodable>: Decodable {
        var code: Int
        var message: String?
        var data: Value?
    }

    private let session: URLSession
    private let navigationEndpoint: URL
    private let searchEndpoint: URL
    private let now: @Sendable () -> Date
    private let keyCache: BilibiliWBIKeyCache

    public init() {
        self.init(
            session: URLSession(configuration: SilentCommunityURLSessionConfiguration.make()),
            navigationEndpoint: URL(string: "https://api.bilibili.com/x/web-interface/nav")!,
            searchEndpoint: URL(string: "https://api.bilibili.com/x/web-interface/wbi/search/type")!
        )
    }

    public init(
        session: URLSession,
        navigationEndpoint: URL,
        searchEndpoint: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.navigationEndpoint = navigationEndpoint
        self.searchEndpoint = searchEndpoint
        self.now = now
        keyCache = BilibiliWBIKeyCache()
    }

    public func search(query: String, limit: Int) async throws -> [CommunityMediaSearchItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SkillDiscoveryError.emptyQuery }
        let timestamp = now()
        let keys = try await wbiKeys(at: timestamp)
        let signedQuery = BilibiliWBISigner.signedQuery(
            parameters: ["search_type": "video", "keyword": trimmed, "page": "1"],
            imageKey: keys.image,
            subKey: keys.sub,
            timestamp: Int64(timestamp.timeIntervalSince1970)
        )
        guard let url = URL(string: "\(searchEndpoint.absoluteString)?\(signedQuery)") else {
            throw SkillDiscoveryError.invalidResponse
        }
        let envelope: Envelope<SearchData> = try await requestJSON(url: url, maximumBytes: 4 * 1_024 * 1_024)
        guard envelope.code == 0, let videos = envelope.data?.result else {
            throw CommunityMediaSourceError.blocked(.bilibili)
        }

        return videos.prefix(min(max(limit, 1), 20)).compactMap { video in
            guard let bvid = video.bvid?.trimmingCharacters(in: .whitespacesAndNewlines), !bvid.isEmpty,
                  let rawTitle = video.title
            else { return nil }
            let title = HTMLTextExtraction.plainText(rawTitle)
            guard !title.isEmpty,
                  let url = URL(string: "https://www.bilibili.com/video/\(bvid)")
            else { return nil }
            return CommunityMediaSearchItem(
                id: "bilibili/\(bvid)",
                platform: .bilibili,
                author: video.author,
                title: title,
                summary: video.description.map(HTMLTextExtraction.plainText),
                url: url,
                engagement: video.play,
                publishedAt: video.publishedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            )
        }
    }

    private func wbiKeys(at date: Date) async throws -> BilibiliWBIKeys {
        if let cached = await keyCache.value(at: date) { return cached }
        let envelope: Envelope<NavigationData> = try await requestJSON(url: navigationEndpoint, maximumBytes: 512 * 1_024)
        guard let image = envelope.data?.wbiImage.imageURL,
              let sub = envelope.data?.wbiImage.subURL,
              let imageKey = Self.key(from: image),
              let subKey = Self.key(from: sub)
        else { throw CommunityMediaSourceError.unreadableOutput(.bilibili) }
        let keys = BilibiliWBIKeys(image: imageKey, sub: subKey, fetchedAt: date)
        await keyCache.store(keys)
        return keys
    }

    private func requestJSON<Value: Decodable>(url: URL, maximumBytes: Int) async throws -> Envelope<Value> {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await DiscoveryNetworkResponseLoader.data(
                for: request,
                session: session,
                maximumBytes: maximumBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SkillDiscoveryError.invalidResponse
        }
        guard let http = response as? HTTPURLResponse else { throw SkillDiscoveryError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw SkillDiscoveryError.requestFailed(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(Envelope<Value>.self, from: data) else {
            throw CommunityMediaSourceError.unreadableOutput(.bilibili)
        }
        return decoded
    }

    private static func key(from url: String) -> String? {
        let filename = URL(string: url)?.deletingPathExtension().lastPathComponent
        guard let filename, filename.count >= 32 else { return nil }
        return filename
    }

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0.0.0 Safari/537.36"
}

private struct BilibiliWBIKeys: Sendable {
    var image: String
    var sub: String
    var fetchedAt: Date
}

private actor BilibiliWBIKeyCache {
    private var cached: BilibiliWBIKeys?

    func value(at date: Date) -> BilibiliWBIKeys? {
        guard let cached, date.timeIntervalSince(cached.fetchedAt) < 20 * 60 * 60 else { return nil }
        return cached
    }

    func store(_ keys: BilibiliWBIKeys) {
        cached = keys
    }
}

private enum SilentCommunityURLSessionConfiguration {
    static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        return configuration
    }
}

private enum HTMLTextExtraction {
    static func firstCapture(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        captures(pattern: pattern, in: text, options: options).first
    }

    static func captures(
        pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }

    static func plainText(_ html: String) -> String {
        var value = html
        value = replacing(pattern: #"<!--[\s\S]*?-->"#, in: value, with: "")
        value = replacing(pattern: #"<[^>]+>"#, in: value, with: " ")
        let entities = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'",
            "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’", "&hellip;": "…", "&rarr;": "→",
        ]
        for (entity, replacement) in entities {
            value = value.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        value = decodeNumericEntities(value)
        return replacing(pattern: #"\s+"#, in: value, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else { return text }
        var value = text
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range(at: 0), in: value),
                  let numberRange = Range(match.range(at: 1), in: value)
            else { continue }
            let raw = String(value[numberRange])
            let radix = raw.lowercased().hasPrefix("x") ? 16 : 10
            let digits = radix == 16 ? String(raw.dropFirst()) : raw
            guard let code = UInt32(digits, radix: radix), let scalar = UnicodeScalar(code) else { continue }
            value.replaceSubrange(whole, with: String(Character(scalar)))
        }
        return value
    }

    private static func replacing(pattern: String, in text: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
    }
}
