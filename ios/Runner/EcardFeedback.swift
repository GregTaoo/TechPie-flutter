import AVFoundation
import CoreHaptics
import Flutter
import UIKit

/// Audio and tactile events use the same pattern and Core Haptics timeline.
final class EcardFeedback {
  private struct Pulse: Decodable {
    let atMs: Double
    let durationMs: Double
    let intensity: Float
    let sharpness: Float
  }

  private struct Pattern: Decodable {
    let audio: String
    let durationMs: Double
    let pulses: [Pulse]
  }

  private enum Failure: Error { case missingAsset, missingPattern, audioUnavailable }
  private let registrar: FlutterPluginRegistrar
  private let channel: FlutterMethodChannel
  private var patterns: [String: Pattern]?
  private var engine: CHHapticEngine?
  private var resources: [String: CHHapticAudioResourceID] = [:]
  private var hapticPlayer: CHHapticPatternPlayer?
  private var audioPlayer: AVAudioPlayer?
  private var work: [DispatchWorkItem] = []
  private var generation = 0

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    channel = FlutterMethodChannel(name: "techpie/feedback", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "play" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, let args = call.arguments as? [String: Any],
            let event = args["event"] as? String else {
        result(nil)
        return
      }
      do {
        try self.play(event, sound: args["sound"] as? Bool == true,
                      vibration: args["vibration"] as? Bool == true)
        result(nil)
      } catch {
        self.stopPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        result(FlutterError(code: "feedback_failed", message: "Feedback could not be played.", details: nil))
      }
    }
  }

  private func assetURL(_ asset: String) throws -> URL {
    let key = registrar.lookupKey(forAsset: asset)
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else { throw Failure.missingAsset }
    return URL(fileURLWithPath: path)
  }

  private func pattern(for event: String) throws -> Pattern {
    if patterns == nil {
      let data = try Data(contentsOf: assetURL("assets/campus_card/data/feedback_patterns.json"))
      patterns = try JSONDecoder().decode([String: Pattern].self, from: data)
    }
    guard let pattern = patterns?[event] else { throw Failure.missingPattern }
    return pattern
  }

  private func play(_ event: String, sound: Bool, vibration: Bool) throws {
    guard sound || vibration else { return }
    let pattern = try pattern(for: event)
    generation += 1
    let current = generation
    stopPlayback()
    let session = AVAudioSession.sharedInstance()
    if sound {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
    }
    if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
      do {
        try playSynchronized(pattern, sound: sound, vibration: vibration, session: session)
      } catch {
        // Keep audio usable after an engine interruption or on older devices.
        try playFallback(pattern, sound: sound, vibration: vibration, generation: current)
      }
    } else {
      // iOS simulators and iPads may provide audio without a haptic engine.
      try playFallback(pattern, sound: sound, vibration: vibration, generation: current)
    }
    #if DEBUG
    NSLog("TechPieFeedback play %@ sound=%d vibration=%d", event, sound ? 1 : 0, vibration ? 1 : 0)
    #endif
    let cleanup = DispatchWorkItem { [weak self] in
      guard let self, self.generation == current else { return }
      self.stopPlayback()
      try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
    work.append(cleanup)
    DispatchQueue.main.asyncAfter(deadline: .now() + pattern.durationMs / 1000 + 0.04, execute: cleanup)
  }

  private func playSynchronized(_ pattern: Pattern, sound: Bool, vibration: Bool, session: AVAudioSession) throws {
    if engine == nil {
      let created = try CHHapticEngine(audioSession: session)
      created.isAutoShutdownEnabled = true
      created.resetHandler = { [weak self] in
        DispatchQueue.main.async { self?.resources.removeAll() }
      }
      engine = created
    }
    guard let engine else { throw Failure.audioUnavailable }
    try engine.start()
    var events: [CHHapticEvent] = []
    if sound {
      let resource: CHHapticAudioResourceID
      if let cached = resources[pattern.audio] {
        resource = cached
      } else {
        if #available(iOS 15.0, *) {
          resource = try engine.registerAudioResource(assetURL(pattern.audio), options: [CHHapticAudioResourceKeyUseVolumeEnvelope: false])
        } else {
          resource = try engine.registerAudioResource(assetURL(pattern.audio), options: [:])
        }
        resources[pattern.audio] = resource
      }
      events.append(CHHapticEvent(audioResourceID: resource,
        parameters: [CHHapticEventParameter(parameterID: .audioVolume, value: 1)], relativeTime: 0))
    }
    if vibration {
      events.append(contentsOf: pattern.pulses.map { pulse in
        CHHapticEvent(eventType: .hapticTransient, parameters: [
          CHHapticEventParameter(parameterID: .hapticIntensity, value: pulse.intensity),
          CHHapticEventParameter(parameterID: .hapticSharpness, value: pulse.sharpness),
        ], relativeTime: pulse.atMs / 1000)
      })
    }
    let player = try engine.makePlayer(with: CHHapticPattern(events: events, parameters: []))
    hapticPlayer = player
    try player.start(atTime: CHHapticTimeImmediate)
  }

  private func playFallback(_ pattern: Pattern, sound: Bool, vibration: Bool, generation: Int) throws {
    let lead = 0.02
    if sound {
      let player = try AVAudioPlayer(contentsOf: assetURL(pattern.audio))
      guard player.prepareToPlay(), player.play(atTime: player.deviceCurrentTime + lead) else { throw Failure.audioUnavailable }
      audioPlayer = player
    }
    if vibration {
      for pulse in pattern.pulses {
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        generator.prepare()
        let item = DispatchWorkItem { [weak self] in
          guard self?.generation == generation else { return }
          generator.impactOccurred(intensity: CGFloat(pulse.intensity))
        }
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + lead + pulse.atMs / 1000, execute: item)
      }
    }
  }

  private func stopPlayback() {
    work.forEach { $0.cancel() }
    work.removeAll()
    try? hapticPlayer?.stop(atTime: CHHapticTimeImmediate)
    hapticPlayer = nil
    audioPlayer?.stop()
    audioPlayer = nil
  }
}
