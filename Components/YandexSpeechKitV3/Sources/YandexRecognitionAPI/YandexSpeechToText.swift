//
//  YandexSpeechToText.swift
//  YandexSpeechKit
//
//  Created by Vladislav Popovich on 28.01.2020.
//  Copyright © 2020 Just Ai. All rights reserved.
//

import AVFoundation
import Foundation

public
class YandexSpeechToText: AimyboxComponent, SpeechToText {
    /**
    Customize `config` parameter if you change recognition audioFormat in recognition config.
    */
    public
    var audioFormat: AVAudioFormat = .defaultFormat
    /**
    Debounce delay in seconds. Higher values results in higher lag between partial and final results.
    */
    public
    var delayAfterSpeech: TimeInterval = 1.0
    /**
    Used to notify *Aimybox* state machine about events.
    */
    public
    var notify: (SpeechToTextCallback)?
    /**
    Used for audio signal processing.
    */
    private
    let audioEngine: AVAudioEngine
    /**
    Node on which audio stream is routed.
    */
    private
    var audioInputNode: AVAudioNode?
    /**
    */
    private
    lazy var recognitionAPI = YandexRecognitionAPI(
        iAMToken: iamToken,
        folderID: folderID,
        language: languageCode,
        host: host,
        port: port,
        config: config,
        dataLoggingEnabled: dataLoggingEnabled,
        normalizePartialData: normalizePartialData,
        operation: operationQueue
    )
    /**
    */
    private
    var wasSpeechStopped = true

    private
    let iamToken: String

    private
    let folderID: String

    private
    let languageCode: String

    private
    let host: String

    private
    let port: Int
    
    private
    let config: Yandex_Cloud_Ai_Stt_V2_RecognitionConfig?

    private
    let dataLoggingEnabled: Bool

    private
    let normalizePartialData: Bool
    /**
    Debouncer used to control delay time of acquiring final results of speech recognizing process.
    */
    private
    var recognitionDebouncer: DispatchDebouncer

    /**
    Init that uses provided params.
    */
    public
    init?(
        tokenProvider: IAMTokenProvider,
        folderID: String,
        language code: String = "ru-RU",
        host: String = "stt.api.cloud.yandex.net",
        port: Int = 443,
        config: Yandex_Cloud_Ai_Stt_V2_RecognitionConfig? = nil,
        dataLoggingEnabled: Bool = false,
        normalizePartialData: Bool = false
    ) {
        let token = tokenProvider.token()

        guard let iamToken = token?.iamToken else {
            return nil
        }

        self.iamToken = iamToken
        self.folderID = folderID
        self.languageCode = code
        self.host = host
        self.port = port
        self.audioEngine = AVAudioEngine()
        self.config = config
        self.dataLoggingEnabled = dataLoggingEnabled
        self.normalizePartialData = normalizePartialData
        recognitionDebouncer = DispatchDebouncer()
        super.init()
    }

    public
    func startRecognition() {
        guard wasSpeechStopped else {
            return
        }
        wasSpeechStopped = false

        checkPermissions { [weak self] result in
            switch result {
            case .success:
                self?.onPermissionGranted()
            default:
                self?.notify?(result)
            }
        }
    }

    public
    func stopRecognition() {
        wasSpeechStopped = true
        audioEngine.stop()
        audioInputNode?.removeTap(onBus: 0)
        audioInputNode = nil
        recognitionAPI.closeStream()
    }

    public
    func cancelRecognition() {
        wasSpeechStopped = true
        audioEngine.stop()
        audioInputNode?.removeTap(onBus: 0)
        audioInputNode = nil
        operationQueue.addOperation { [weak self] in
            self?.recognitionAPI.closeStream()
            self?.notify?(.success(.recognitionCancelled))
        }
    }

    // MARK: - Internals

    private
    func onPermissionGranted() {
        prepareRecognition()
        guard !wasSpeechStopped else {
            return
        }

        do {
            try audioEngine.start()
            notify?(.success(.recognitionStarted))
        } catch {
            notify?(.failure(.microphoneUnreachable))
        }
    }

    private
    // swiftlint:disable:next function_body_length superfluous_disable_command
    func prepareRecognition() {
        guard let notify = notify else {
            return
        }

        prepareAudioEngineForMultiRoute {
            if !$0 {
                notify(.failure(.microphoneUnreachable))
            }
        }

        // swiftlint:disable:next closure_body_length
        recognitionAPI.openStream { [audioEngine, weak self, audioFormat] stream in
            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            let recordingFormat = audioFormat

            try? AVAudioSession.sharedInstance().setPreferredSampleRate(inputFormat.sampleRate)

            let converter = AVAudioConverter(from: inputFormat, to: recordingFormat)
            let ratio = Float(inputFormat.sampleRate) / Float(
                recordingFormat.sampleRate > 0 ? recordingFormat.sampleRate : AVAudioFormat.defaultFormat.sampleRate
            )

            inputNode.removeTap(onBus: 0)
            // swiftlint:disable:next closure_body_length
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                // swiftlint:disable:next closure_body_length
                let request = YandexRecognitionAPI.Request.with { request in
                    let capacity = UInt32(Float(buffer.frameCapacity) / Float(ratio > 0 ? ratio : 1))
                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: recordingFormat,
                        frameCapacity: capacity
                    ) else {
                        return
                    }

                    outputBuffer.frameLength = outputBuffer.frameCapacity

                    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                        outStatus.pointee = AVAudioConverterInputStatus.haveData
                        return buffer
                    }

                    let status = converter?.convert(
                        to: outputBuffer,
                        error: nil,
                        withInputFrom: inputBlock
                    )

                    switch status {
                    case .error:
                        return
                    default:
                        break
                    }

                    guard let bytes = outputBuffer.int16ChannelData else {
                        return
                    }

                    let channels = UnsafeBufferPointer(start: bytes, count: Int(audioFormat.channelCount))

                    request.audioContent = Data(
                        bytesNoCopy: channels[0],
                        count: Int(buffer.frameCapacity * audioFormat.streamDescription.pointee.mBytesPerFrame),
                        deallocator: .none
                    )
                }
                stream?.sendMessage(request, promise: nil)
            }

            self?.audioInputNode = inputNode
            audioEngine.prepare()

        } onResponse: { [weak self] response in
            self?.processResults(response)
        }
    }

    private
    func processResults(_ response: Yandex_Cloud_Ai_Stt_V2_StreamingRecognitionResponse) {
        guard
            !wasSpeechStopped,
            let phrase = response.chunks.first,
            let bestAlternative = phrase.alternatives.first
        else {
            return
        }

        guard phrase.final == true else {
            notify?(.success(.recognitionPartialResult(bestAlternative.text)))
            return
        }

        let finalResult = bestAlternative.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard finalResult.isEmpty == false else {
            notify?(.success(.emptyRecognitionResult))
            return
        }

        recognitionDebouncer.debounce(delay: delayAfterSpeech) { [weak self] in
            self?.notify?(.success(.recognitionPartialResult(finalResult)))
            self?.notify?(.success(.recognitionResult(finalResult)))
            self?.stopRecognition()
        }
    }

    // MARK: - User Permissions

    private
    func checkPermissions(_ completion: @escaping (SpeechToTextResult) -> Void ) {
        var recordAllowed = false
        let permissionsDispatchGroup = DispatchGroup()

        permissionsDispatchGroup.enter()
        // Microphone recording permission
        AVAudioSession.sharedInstance().requestRecordPermission { isAllowed in
            recordAllowed = isAllowed
            permissionsDispatchGroup.leave()
        }

        permissionsDispatchGroup.notify(queue: .global(qos: .userInteractive)) {
            if recordAllowed {
                completion(.success(.recognitionPermissionsGranted))
            } else {
                completion(.failure(.microphonePermissionReject))
            }
        }
    }
}

extension AVAudioFormat {
    static var defaultFormat: AVAudioFormat {
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            fatalError()
        }
        return audioFormat
    }
}
