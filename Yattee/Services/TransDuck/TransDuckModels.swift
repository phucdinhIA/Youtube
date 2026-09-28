//
//  TransDuckModels.swift
//  Yattee
//
//  Native subtitle and dubbing values used by the TransDuck integration.
//

import Foundation

struct TransDuckCue: Codable, Hashable, Sendable {
    let index: Int
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { end - start }
}

struct TransDuckTranslation: Hashable, Sendable {
    let cue: TransDuckCue
    let text: String
    let usedAI: Bool
}

struct TransDuckAudioSegment: Hashable, Sendable {
    let cue: TransDuckCue
    let url: URL
}

enum TransDuckModel: String, CaseIterable, Identifiable, Sendable {
    case google
    case gemini = "gemini-3.5-flash-lite"
    case deepSeek = "deepseek-v4-flash"
    case gpt = "gpt-5.6-sol"
    case gptFast = "gpt-5.6-luna"
    case claude = "claude-opus-5"
    case claudeSonnet = "claude-sonnet-5"
    case claudeHaiku = "claude-haiku-4-5-20251001"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: "Google"
        case .gemini: "Gemini 3.5 Flash Lite"
        case .deepSeek: "DeepSeek V4 Flash"
        case .gpt: "GPT 5.6 Sol"
        case .gptFast: "GPT 5.6 Luna"
        case .claude: "Claude Opus 5"
        case .claudeSonnet: "Claude Sonnet 5"
        case .claudeHaiku: "Claude Haiku 4.5"
        }
    }
}

enum TransDuckVoice: String, CaseIterable, Identifiable, Sendable {
    case hoaiMy = "vi-VN-HoaiMyNeural"
    case namMinh = "vi-VN-NamMinhNeural"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hoaiMy: "Hoài My"
        case .namMinh: "Nam Minh"
        }
    }
}

enum TransDuckError: Error, LocalizedError, Equatable, Sendable {
    case invalidCredentials
    case unauthorized
    case badResponse(Int)
    case malformedResponse
    case noCaptions
    case emptyAudio
    case invalidSubtitle

    var errorDescription: String? {
        switch self {
        case .invalidCredentials: "The account email or password is incorrect."
        case .unauthorized: "Sign in to TransDuck before using dubbing."
        case .badResponse(let status): "TransDuck returned HTTP \(status)."
        case .malformedResponse: "TransDuck returned an unexpected response."
        case .noCaptions: "This video does not have a usable caption track."
        case .emptyAudio: "TransDuck did not return playable speech."
        case .invalidSubtitle: "The caption file does not contain timed text."
        }
    }
}
