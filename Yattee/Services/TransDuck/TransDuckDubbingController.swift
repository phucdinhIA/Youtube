//
//  TransDuckDubbingController.swift
//  Yattee
//
//  Bridges TransDuck translations and speech into Yattee's native player.
//

import Foundation
import AVFoundation
import SwiftUI

@MainActor
@Observable
final class TransDuckDubbingController {
    static let shared = TransDuckDubbingController()

    private let client = TransDuckClient()
    private let audioCache = NSCache<NSString, NSData>()
    private var audioPlayer: AVAudioPlayer?
    private var audioTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var activeVideoID: String?
    private var activeSegmentIndex: Int?
    private var originalVolume: Float?
    private var translationVolume: Float = 1
    private weak var playerService: PlayerService?
    private(set) var segments: [TransDuckAudioSegment] = []
    private(set) var isPreparing = false
    private(set) var statusText = ""
    private(set) var isActive = false

    private init() {
        audioCache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func signIn(email: String, password: String) async throws {
        try await client.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    }

    func hasSession() async -> Bool {
        (try? await client.account().exists) == true
    }

    func prepare(
        video: Video,
        caption: Caption?,
        playerService: PlayerService,
        model: TransDuckModel,
        voice: TransDuckVoice,
        enableSpeech: Bool,
        originalAudioLevel: Float,
        translationAudioLevel: Float,
        bilingualSubtitles: Bool
    ) async throws {
        guard !isPreparing else { return }
        stop(restoreVolume: true)
        isPreparing = true
        statusText = "Đang đọc phụ đề…"
        defer { isPreparing = false }

        let cues: [TransDuckCue]
        if let caption {
            let (data, response) = try await URLSession.shared.data(from: caption.url)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw TransDuckError.noCaptions
            }
            cues = try TransDuckCaptionParser.parseWebVTT(data)
        } else {
            cues = try await client.youtubeCaptions(videoID: video.id.videoID)
        }
        guard !cues.isEmpty else { throw TransDuckError.noCaptions }
        try Task.checkCancellation()

        statusText = "Đang dịch \(cues.count) câu…"
        let translated = try await client.translate(
            videoID: video.id.videoID,
            title: video.title,
            cues: cues,
            model: model,
            sourceLanguage: caption?.baseLanguageCode ?? "auto"
        )
        let subtitleURL = try TransDuckCaptionParser.makeSRT(translated, bilingual: bilingualSubtitles)
        try Task.checkCancellation()

        guard playerService.state.currentVideo?.id == video.id else {
            throw TransDuckError.noCaptions
        }
        playerService.loadCaption(Caption(label: "Tiếng Việt · TransDuck", languageCode: "vi-VN", url: subtitleURL))

        activeVideoID = video.id.videoID
        self.playerService = playerService
        if enableSpeech {
            statusText = "Đang tạo giọng \(voice.displayName)…"
            let generated = try await client.synthesize(
                videoID: video.id.videoID,
                title: video.title,
                translations: translated,
                model: model,
                voice: voice
            )
            guard playerService.state.currentVideo?.id == video.id else { return }
            segments = generated
            translationVolume = min(max(translationAudioLevel, 0), 1)
            originalVolume = playerService.state.volume
            let level = min(max(originalAudioLevel, 0), 1)
            playerService.state.volume = level
            playerService.currentBackend?.volume = level
            isActive = true
            updatePlayback(time: playerService.state.currentTime, isPlaying: playerService.state.playbackState == .playing, videoID: video.id.videoID)
            startPlaybackMonitor()
        }
        statusText = enableSpeech ? "Phụ đề và lồng tiếng đã sẵn sàng." : "Phụ đề tiếng Việt đã sẵn sàng."
    }

    /// Keep speech synchronized when the expanded player sheet is closed or PiP is active.
    private func startPlaybackMonitor() {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let playerService = self.playerService else { return }
                self.updatePlayback(
                    time: playerService.state.currentTime,
                    isPlaying: playerService.state.playbackState == .playing,
                    videoID: playerService.state.currentVideo?.id.videoID
                )
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func updatePlayback(time: TimeInterval, isPlaying: Bool, videoID: String?) {
        guard isActive else { return }
        guard videoID == activeVideoID else {
            stop(restoreVolume: true)
            return
        }
        guard isPlaying else {
            audioPlayer?.pause()
            return
        }

        guard let index = segments.firstIndex(where: { time >= $0.cue.start && time < $0.cue.end }) else {
            audioTask?.cancel()
            audioPlayer?.stop()
            activeSegmentIndex = nil
            return
        }
        if activeSegmentIndex == index {
            if let audioPlayer {
                let expectedOffset = max(0, time - segments[index].cue.start)
                if abs(audioPlayer.currentTime - expectedOffset) > 0.35 {
                    audioPlayer.currentTime = min(expectedOffset, audioPlayer.duration)
                }
                audioPlayer.rate = min(max(Float(playerService?.state.rate.rawValue ?? 1), 0.5), 2)
                if !audioPlayer.isPlaying { audioPlayer.play() }
            }
            return
        }

        audioTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        activeSegmentIndex = index
        let segment = segments[index]
        prefetch(after: index)
        audioTask = Task { [weak self] in
            guard let self else { return }
            do {
                let cacheKey = segment.url.absoluteString as NSString
                let data: Data
                if let cached = self.audioCache.object(forKey: cacheKey) {
                    data = cached as Data
                } else {
                    data = try await self.client.audioData(at: segment.url)
                    self.audioCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                }
                guard !Task.isCancelled,
                      self.activeSegmentIndex == index,
                      self.activeVideoID == videoID,
                      let playerService = self.playerService else { return }

                let currentTime = playerService.state.currentTime
                guard currentTime < segment.cue.end else { return }
                let player = try AVAudioPlayer(data: data)
                player.enableRate = true
                player.volume = self.translationVolume
                player.rate = min(max(Float(playerService.state.rate.rawValue), 0.5), 2)
                player.prepareToPlay()
                player.currentTime = min(max(0, currentTime - segment.cue.start), player.duration)
                self.audioPlayer = player
                if playerService.state.playbackState == .playing { player.play() }
            } catch {
                self.statusText = error.localizedDescription
            }
        }
    }

    private func prefetch(after index: Int) {
        prefetchTask?.cancel()
        let first = index + 1
        guard first < segments.count else { return }
        let next = Array(segments[first..<min(first + 3, segments.count)])
        let videoID = activeVideoID
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            for segment in next {
                guard !Task.isCancelled, self.activeVideoID == videoID else { return }
                let key = segment.url.absoluteString as NSString
                if self.audioCache.object(forKey: key) != nil { continue }
                guard let data = try? await self.client.audioData(at: segment.url) else { continue }
                self.audioCache.setObject(data as NSData, forKey: key, cost: data.count)
            }
        }
    }

    func stop(restoreVolume: Bool) {
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        audioTask?.cancel()
        audioTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if restoreVolume, let originalVolume, let playerService {
            playerService.state.volume = originalVolume
            playerService.currentBackend?.volume = originalVolume
        }
        originalVolume = nil
        activeVideoID = nil
        activeSegmentIndex = nil
        segments = []
        isActive = false
    }
}
