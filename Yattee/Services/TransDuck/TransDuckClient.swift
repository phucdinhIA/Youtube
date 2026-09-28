//
//  TransDuckClient.swift
//  Yattee
//
//  Native authenticated client for subtitle translation and Azure speech.
//

import Foundation

actor TransDuckClient {
    private let baseURL = URL(string: "https://yd.transduck.com")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.httpCookieStorage = .shared
            configuration.httpShouldSetCookies = true
            configuration.timeoutIntervalForRequest = 75
            self.session = URLSession(configuration: configuration)
        }
    }

    func signIn(email: String, password: String) async throws {
        guard !email.isEmpty, !password.isEmpty else {
            throw TransDuckError.invalidCredentials
        }
        var request = URLRequest(url: baseURL.appending(path: "/login"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: email),
            URLQueryItem(name: "password", value: password)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)
        _ = try await perform(request)
        guard try await account().exists else { throw TransDuckError.invalidCredentials }
    }

    func account() async throws -> TransDuckAccount {
        let data = try await get("/api/v2/membership/getPopupInfo")
        return try decode(TransDuckAccount.self, from: data)
    }

    func youtubeCaptions(videoID: String) async throws -> [TransDuckCue] {
        var components = URLComponents(url: baseURL.appending(path: "/api/v2/subtitle/getYoutubeSubtitleList"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "videoId", value: videoID),
            URLQueryItem(name: "version", value: "1.0")
        ]
        guard let url = components.url else { throw TransDuckError.malformedResponse }
        let items = try decode([BackendCaption].self, from: try await perform(URLRequest(url: url)))
        return items.enumerated().compactMap { index, item in
            guard let start = TimeInterval(item.timing.start),
                  let duration = TimeInterval(item.timing.dur),
                  start >= 0, duration > 0 else { return nil }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TransDuckCue(index: index, text: text, start: start, end: start + duration)
        }
    }

    func translate(
        videoID: String,
        title: String,
        cues: [TransDuckCue],
        model: TransDuckModel,
        sourceLanguage: String,
        targetLanguage: String = "vi-VN"
    ) async throws -> [TransDuckTranslation] {
        guard !cues.isEmpty else { throw TransDuckError.noCaptions }
        if model == .google {
            return try await translateWithGoogle(
                videoID: videoID,
                cues: cues,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        }
        var translated: [TransDuckTranslation] = []
        for batch in cues.chunked(into: 10) {
            let payload = TranslationRequest(
                videoId: videoID,
                title: title,
                model: model.rawValue,
                toLanguage: targetLanguage,
                domain: "general",
                translationRulesEnabled: false,
                skipTranslation: false,
                subtitles: batch.map {
                    TranslationRequest.Cue(
                        index: $0.index,
                        text: $0.text,
                        googleTranslation: $0.text,
                        start: $0.start,
                        end: $0.end
                    )
                }
            )
            let data = try await post("/api/v2/ai-translate/translate", payload)
            let response = try decode(TranslationResponse.self, from: data)
            guard response.subtitleTranslateResults.count == batch.count else {
                throw TransDuckError.malformedResponse
            }
            translated += zip(batch, response.subtitleTranslateResults).map { cue, result in
                TransDuckTranslation(
                    cue: cue,
                    text: result.translateResult.isEmpty ? cue.text : result.translateResult,
                    usedAI: result.useAiTranslate
                )
            }
        }
        return translated
    }

    private func translateWithGoogle(
        videoID: String,
        cues: [TransDuckCue],
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> [TransDuckTranslation] {
        var translated: [TransDuckTranslation] = []
        for batch in cues.chunked(into: 50) {
            var components = URLComponents(url: baseURL.appending(path: "/api/v2/translateAll"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "language", value: sourceLanguage),
                URLQueryItem(name: "to", value: targetLanguage),
                URLQueryItem(name: "videoId", value: videoID),
                URLQueryItem(name: "platform", value: "pc")
            ]
            guard let url = components.url else { throw TransDuckError.malformedResponse }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(batch.map(\.text))
            let response = try decode(GoogleTranslationResponse.self, from: try await perform(request))
            guard response.translations.count == batch.count else { throw TransDuckError.malformedResponse }
            translated += zip(batch, response.translations).map { cue, result in
                TransDuckTranslation(cue: cue, text: result.text, usedAI: false)
            }
        }
        return translated
    }

    func synthesize(
        videoID: String,
        title: String,
        translations: [TransDuckTranslation],
        model: TransDuckModel,
        voice: TransDuckVoice
    ) async throws -> [TransDuckAudioSegment] {
        guard !translations.isEmpty else { throw TransDuckError.noCaptions }
        var segments: [TransDuckAudioSegment] = []
        for batch in translations.chunked(into: 10) {
            let payload = DubbingRequest(
                subtitles: batch.map {
                    DubbingRequest.Cue(
                        index: $0.cue.index,
                        text: $0.text,
                        start: $0.cue.start,
                        end: $0.cue.end
                    )
                },
                config: .init(
                    model: model.rawValue,
                    voice: voice.rawValue,
                    voiceType: "azure",
                    toLanguage: "vi-VN",
                    skipTranslation: true
                ),
                videoDetails: .init(videoId: videoID, title: title, subtitleLevel: 2),
                v2Version: true
            )
            let data = try await post("/api/v2/dubbing/generateDubbing", payload)
            let response = try decode(DubbingResponse.self, from: data)
            guard response.subtitleDubbingResults.count == batch.count else {
                throw TransDuckError.malformedResponse
            }
            for (translation, result) in zip(batch, response.subtitleDubbingResults) {
                guard let url = URL(string: result.ttsUrl),
                      url.scheme == "https",
                      !url.lastPathComponent.lowercased().contains("empty_audio") else {
                    throw TransDuckError.emptyAudio
                }
                segments.append(TransDuckAudioSegment(cue: translation.cue, url: url))
            }
        }
        return segments
    }

    func audioData(at url: URL) async throws -> Data {
        // The backend may return audio from different CDNs. Only accept HTTPS,
        // including after redirects, instead of assuming a single CDN domain.
        guard url.scheme == "https", url.host != nil else {
            throw TransDuckError.malformedResponse
        }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw TransDuckError.malformedResponse }
        guard response.url?.scheme == "https" else { throw TransDuckError.malformedResponse }
        guard (200..<300).contains(response.statusCode) else {
            throw TransDuckError.badResponse(response.statusCode)
        }
        guard data.count > 1_000 else { throw TransDuckError.emptyAudio }
        return data
    }

    private func get(_ path: String) async throws -> Data {
        try await perform(URLRequest(url: baseURL.appending(path: path)))
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TransDuckError.malformedResponse }
        if response.statusCode == 401 || response.statusCode == 403 {
            throw TransDuckError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw TransDuckError.badResponse(response.statusCode)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String, error == "Unauthorized" {
            throw TransDuckError.unauthorized
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TransDuckError.malformedResponse }
    }
}

struct TransDuckAccount: Decodable, Sendable {
    let exists: Bool
    let balance: Double?
    let membership: Membership?

    struct Membership: Decodable, Sendable {
        let level: Int
    }
}

private struct TranslationRequest: Encodable {
    let videoId: String
    let title: String
    let model: String
    let toLanguage: String
    let domain: String
    let translationRulesEnabled: Bool
    let skipTranslation: Bool
    let subtitles: [Cue]

    struct Cue: Encodable {
        let index: Int
        let text: String
        let googleTranslation: String
        let start: TimeInterval
        let end: TimeInterval
    }
}

private struct BackendCaption: Decodable {
    let text: String
    let timing: Timing

    enum CodingKeys: String, CodingKey {
        case text = "_"
        case timing = "$"
    }

    struct Timing: Decodable {
        let start: String
        let dur: String
    }
}

private struct TranslationResponse: Decodable {
    let subtitleTranslateResults: [Result]

    struct Result: Decodable {
        let translateResult: String
        let useAiTranslate: Bool
    }
}

private struct GoogleTranslationResponse: Decodable {
    let translations: [Result]

    struct Result: Decodable {
        let text: String
    }
}

private struct DubbingRequest: Encodable {
    let subtitles: [Cue]
    let config: Config
    let videoDetails: VideoDetails
    let v2Version: Bool

    struct Cue: Encodable {
        let index: Int
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    struct Config: Encodable {
        let model: String
        let voice: String
        let voiceType: String
        let toLanguage: String
        let skipTranslation: Bool
    }

    struct VideoDetails: Encodable {
        let videoId: String
        let title: String
        let subtitleLevel: Int
    }
}

private struct DubbingResponse: Decodable {
    let subtitleDubbingResults: [Result]

    struct Result: Decodable {
        let ttsUrl: String
    }
}

