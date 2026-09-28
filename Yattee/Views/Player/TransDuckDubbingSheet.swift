//
//  TransDuckDubbingSheet.swift
//  Yattee
//
//  iPad-friendly controls for native Vietnamese translation and dubbing.
//

import SwiftUI

#if os(iOS)
struct TransDuckDubbingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let video: Video
    let playerService: PlayerService

    @State private var controller = TransDuckDubbingController.shared
    @State private var email = ""
    @State private var password = ""
    @State private var signedIn = false
    @State private var isSigningIn = false
    @State private var selectedModel: TransDuckModel = .gemini
    @State private var selectedVoice: TransDuckVoice = .hoaiMy
    @State private var selectedCaptionID = ""
    @State private var enableSpeech = true
    @State private var bilingualSubtitles = false
    @State private var originalAudioLevel = 0.2
    @State private var translationAudioLevel = 1.0
    @State private var errorMessage: String?

    private var captions: [Caption] { playerService.availableCaptions }
    private var selectedCaption: Caption? {
        captions.first(where: { $0.id == selectedCaptionID }) ?? captions.first
    }

    var body: some View {
        NavigationStack {
            Form {
                if !signedIn { accountSection }
                Section("Video") {
                    Text(video.title).lineLimit(2)
                    if captions.isEmpty {
                        Label("Sẽ kiểm tra phụ đề lưu trên TransDuck.", systemImage: "text.magnifyingglass")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Phụ đề gốc", selection: $selectedCaptionID) {
                            ForEach(captions) { caption in
                                Text(caption.displayName).tag(caption.id)
                            }
                        }
                    }
                }

                Section("Bản dịch") {
                    Picker("Mô hình", selection: $selectedModel) {
                        ForEach(TransDuckModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    LabeledContent("Ngôn ngữ đích", value: "Tiếng Việt")
                    Toggle("Phụ đề song ngữ", isOn: $bilingualSubtitles)
                }

                Section("Lồng tiếng") {
                    Toggle("Bật lồng tiếng", isOn: $enableSpeech)
                    if enableSpeech {
                        Picker("Giọng Azure", selection: $selectedVoice) {
                            ForEach(TransDuckVoice.allCases) { voice in
                                Text(voice.displayName).tag(voice)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Âm lượng video gốc: \(Int(originalAudioLevel * 100))%")
                            Slider(value: $originalAudioLevel, in: 0...1)
                            Text("Âm lượng lồng tiếng: \(Int(translationAudioLevel * 100))%")
                            Slider(value: $translationAudioLevel, in: 0...1)
                        }
                    }
                }

                if controller.isPreparing || !controller.statusText.isEmpty {
                    Section("Trạng thái") {
                        HStack(spacing: 12) {
                            if controller.isPreparing { ProgressView() }
                            Text(controller.statusText)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        startDubbing()
                    } label: {
                        Label("Dịch và lồng tiếng", systemImage: "waveform")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!signedIn || controller.isPreparing)

                    if controller.isActive {
                        Button("Dừng lồng tiếng", role: .destructive) {
                            controller.stop(restoreVolume: true)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .navigationTitle("TransDuck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .task {
            signedIn = await controller.hasSession()
            if selectedCaptionID.isEmpty { selectedCaptionID = captions.first?.id ?? "" }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var accountSection: some View {
        Section("Tài khoản TransDuck") {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Mật khẩu", text: $password)
                .textContentType(.password)
            Button {
                signIn()
            } label: {
                HStack {
                    Text("Đăng nhập")
                    if isSigningIn { Spacer(); ProgressView() }
                }
            }
            .disabled(isSigningIn || email.isEmpty || password.isEmpty)
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await controller.signIn(email: email, password: password)
                password = ""
                signedIn = true
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startDubbing() {
        errorMessage = nil
        Task {
            do {
                try await controller.prepare(
                    video: video,
                    caption: selectedCaption,
                    playerService: playerService,
                    model: selectedModel,
                    voice: selectedVoice,
                    enableSpeech: enableSpeech,
                    originalAudioLevel: Float(originalAudioLevel),
                    translationAudioLevel: Float(translationAudioLevel),
                    bilingualSubtitles: bilingualSubtitles
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
