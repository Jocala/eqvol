//
//  eqVol — standalone menu-bar volume for HDMI displays without volume control
//
//  A virtual audio device (the eqvol.driver HAL plugin, built from driver/,
//  installed system-wide) receives system audio; this app taps its output
//  mix with a CoreAudio device tap into a ring buffer,
//  then a second AVAudioEngine pulls the ring through a PID-controlled
//  varispeed + gain mixer into the real output device. Volume/Balance controls
//  on the virtual device (what F-keys and this slider write) are mirrored to
//  the gain mixer, so macOS gets working volume control over an HDMI sink that
//  has none (no CEC).
//
//  Requires: /Library/Audio/Plug-Ins/HAL/eqvol.driver (built from driver/)
//

import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import ServiceManagement
import os

// MARK: - Constants

let DRIVER_DEVICE_UID = "EQVolDevice"

func fourCC(_ string: String) -> AudioObjectPropertySelector {
  var value: UInt32 = 0
  for byte in string.utf8.prefix(4) {
    value = (value << 8) | UInt32(byte)
  }
  return value
}

var shownAddress: AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: fourCC("shwn"),
                             mScope: kAudioObjectPropertyScopeGlobal,
                             mElement: kAudioObjectPropertyElementMain)
}

var customNameAddress: AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: fourCC("eqvn"),
                             mScope: kAudioObjectPropertyScopeGlobal,
                             mElement: kAudioObjectPropertyElementMain)
}

// MARK: - CoreAudio helpers

enum CA {
  static func defaultOutputDevice() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &id) == noErr else { return 0 }
    return id
  }

  @discardableResult
  static func setDefaultOutputDevice(_ device: AudioDeviceID) -> OSStatus {
    var id = device
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                            &address, 0, nil, size, &id)
    NSLog("eqvol: setDefaultOutputDevice(%d) status=%d readback=%d", device, status, defaultOutputDevice())
    return status
  }

  /// Translates a device UID to a device ID. Works even while the device is
  /// hidden from enumeration (the driver answers translation always).
  static func deviceByUID(_ uid: String) -> AudioDeviceID? {
    var cfUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let qualifierSize = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { qualifier in
      withUnsafeMutablePointer(to: &deviceID) { out in
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &address, qualifierSize, qualifier, &size, out)
      }
    }
    guard status == noErr, deviceID != 0, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
    return deviceID
  }

  static func isHidden(_ device: AudioDeviceID) -> Int? {
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyIsHidden,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return Int(value)
  }

  static func deviceName(_ device: AudioDeviceID) -> String {
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return "?" }
    return name as String
  }

  static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
    // kAudioDevicePropertyStreams size query returns the byte size of the
    // stream-ID list; >0 means the device has at least one stream.
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
    return size > 0
  }

  static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
    var rate = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 48000 }
    return rate
  }

  static func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
    var value = Float64(rate)
    var size = UInt32(MemoryLayout<Float64>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
  }

  static func bufferFrameSize(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyBufferFrameSize,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 512 }
    return value
  }

  static func safetyOffset(_ device: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertySafetyOffset,
      mScope: scope,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return 0 }
    return value
  }

  /// Lists output devices excluding the driver's virtual device.
  static func realOutputDevices(excluding: AudioDeviceID) -> [AudioDeviceID] {
    var size: UInt32 = 0
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.filter { $0 != excluding && hasOutputStreams($0) }
  }

  // MARK: Volume / Mute controls (per-device)

  static func elements(on device: AudioDeviceID,
                       selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
    var found: [AudioObjectPropertyElement] = []
    var master = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    if AudioObjectHasProperty(device, &master) {
      found.append(kAudioObjectPropertyElementMain)
    } else {
      for channel: AudioObjectPropertyElement in 1..<32 {
        var address = AudioObjectPropertyAddress(
          mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: channel)
        if AudioObjectHasProperty(device, &address) { found.append(channel) }
      }
    }
    return found
  }

  static func getVolume(on device: AudioDeviceID) -> Double? {
    guard let element = elements(on: device, selector: kAudioDevicePropertyVolumeScalar).first else { return nil }
    var value = Float32(0)
    var size = UInt32(MemoryLayout<Float32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput,
      mElement: element)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return Double(max(0, min(1, value)))
  }

  static func setVolume(_ volume: Double, on device: AudioDeviceID) {
    let scalar = Float32(max(0, min(1, volume)))
    for element in elements(on: device, selector: kAudioDevicePropertyVolumeScalar) {
      var value = scalar
      let size = UInt32(MemoryLayout<Float32>.size)
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput,
        mElement: element)
      AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
  }

  static func getMute(on device: AudioDeviceID) -> Bool? {
    guard let element = elements(on: device, selector: kAudioDevicePropertyMute).first else { return nil }
    var value = UInt32(0)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
      mElement: element)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
    return value != 0
  }

  static func setMute(_ mute: Bool, on device: AudioDeviceID) {
    for element in elements(on: device, selector: kAudioDevicePropertyMute) {
      var value: UInt32 = mute ? 1 : 0
      let size = UInt32(MemoryLayout<UInt32>.size)
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeOutput,
        mElement: element)
      AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
  }

  // MARK: driver custom properties

  static func setDriverShown(_ device: AudioDeviceID, _ shown: Bool) {
    var value: CFBoolean = shown ? kCFBooleanTrue : kCFBooleanFalse
    var address = shownAddress
    AudioObjectSetPropertyData(device, &address, 0, nil,
                               UInt32(MemoryLayout<CFBoolean>.size), &value)
  }

  static func setDriverName(_ device: AudioDeviceID, _ name: String) {
    var value = name as CFString
    var address = customNameAddress
    AudioObjectSetPropertyData(device, &address, 0, nil,
                               UInt32(MemoryLayout<CFString>.size), &value)
  }
}

// MARK: - Ring buffer (time-indexed circular buffer)
// Single writer (device IO thread) / single reader (output render thread).
// Time-indexed with wraparound; reader clips against published bounds.

final class RingBuffer {
  struct Bounds {
    var start: Int64
    var end: Int64
  }

  struct Location {
    var start: Int64
    var end: Int64
  }

  let channels: Int
  let capacity: Int
  private var storage: [UnsafeMutablePointer<Float32>]
  private let boundsLock: OSAllocatedUnfairLock<Bounds>

  init(channels: Int, capacity: Int) {
    self.channels = channels
    let frameCapacity = max(1, capacity)
    self.capacity = frameCapacity
    storage = (0..<channels).map { _ in
      let pointer = UnsafeMutablePointer<Float32>.allocate(capacity: frameCapacity)
      pointer.initialize(repeating: 0, count: frameCapacity)
      return pointer
    }
    boundsLock = OSAllocatedUnfairLock(initialState: Bounds(start: 0, end: 0))
  }

  private func currentBounds() -> Bounds {
    boundsLock.withLock { $0 }
  }

  func currentBoundsForDiagnostics() -> Bounds {
    currentBounds()
  }

  private func setBounds(_ bounds: Bounds) {
    boundsLock.withLock { $0 = bounds }
  }

  // MARK: writer side

  func writeInterleaved(_ source: UnsafePointer<Float32>, frameCount: Int64,
                        channels: Int, start: Int64) {
    let end = start + frameCount
    var bounds = currentBounds()

    if start < bounds.end {
      bounds.start = start
      bounds.end = start
    } else if end - bounds.start <= Int64(capacity) {
      // not wrapped yet
    } else {
      let newStart = end - Int64(capacity)
      bounds.start = newStart
      bounds.end = max(newStart, bounds.end)
    }
    setBounds(bounds)

    let last = bounds.end
    var offset0: Int64
    if start > last {
      let o0 = last % Int64(capacity)
      let o1 = start % Int64(capacity)
      if o0 < o1 {
        zeroRing(offset: o0, count: o1 - o0)
      } else {
        zeroRing(offset: o0, count: Int64(capacity) - o0)
        zeroRing(offset: 0, count: o1)
      }
      offset0 = o1
    } else {
      offset0 = start % Int64(capacity)
    }
    let offset1 = end % Int64(capacity)

    if offset0 < offset1 {
      storeInterleaved(source, sourceOffset: 0, offset: offset0,
                       count: offset1 - offset0, channels: channels)
    } else {
      let count = Int64(capacity) - offset0
      storeInterleaved(source, sourceOffset: 0, offset: offset0, count: count, channels: channels)
      storeInterleaved(source, sourceOffset: count, offset: 0, count: offset1, channels: channels)
    }

    bounds = currentBounds()
    bounds.end = end
    setBounds(bounds)
  }

  func writeDeinterleaved(_ buffers: [UnsafePointer<Float32>], frameCount: Int64, start: Int64) {
    let end = start + frameCount
    var bounds = currentBounds()

    if start < bounds.end {
      bounds.start = start
      bounds.end = start
    } else if end - bounds.start <= Int64(capacity) {
      // not wrapped yet
    } else {
      let newStart = end - Int64(capacity)
      bounds.start = newStart
      bounds.end = max(newStart, bounds.end)
    }
    setBounds(bounds)

    let last = bounds.end
    var offset0: Int64
    if start > last {
      let o0 = last % Int64(capacity)
      let o1 = start % Int64(capacity)
      if o0 < o1 {
        zeroRing(offset: o0, count: o1 - o0)
      } else {
        zeroRing(offset: o0, count: Int64(capacity) - o0)
        zeroRing(offset: 0, count: o1)
      }
      offset0 = o1
    } else {
      offset0 = start % Int64(capacity)
    }
    let offset1 = end % Int64(capacity)

    if offset0 < offset1 {
      storeDeinterleaved(buffers, sourceOffset: 0, offset: offset0, count: offset1 - offset0)
    } else {
      let count = Int64(capacity) - offset0
      storeDeinterleaved(buffers, sourceOffset: 0, offset: offset0, count: count)
      storeDeinterleaved(buffers, sourceOffset: count, offset: 0, count: offset1)
    }

    bounds = currentBounds()
    bounds.end = end
    setBounds(bounds)
  }

  private func storeInterleaved(_ source: UnsafePointer<Float32>, sourceOffset: Int64,
                                offset: Int64, count: Int64, channels: Int) {
    for channel in 0..<min(channels, self.channels) {
      let destination = storage[channel].advanced(by: Int(offset))
      for index in 0..<Int(count) {
        destination[index] = source[Int(sourceOffset) + index * channels + channel]
      }
    }
  }

  private func storeDeinterleaved(_ buffers: [UnsafePointer<Float32>], sourceOffset: Int64,
                                  offset: Int64, count: Int64) {
    for channel in 0..<min(buffers.count, channels) {
      let destination = storage[channel].advanced(by: Int(offset))
      let source = buffers[channel].advanced(by: Int(sourceOffset))
      destination.assign(from: source, count: Int(count))
    }
  }

  private func zeroRing(offset: Int64, count: Int64) {
    for channel in 0..<channels {
      storage[channel].advanced(by: Int(offset)).initialize(repeating: 0, count: Int(count))
    }
  }

  // MARK: reader side

  /// Returns 0 on success, -1 when the requested range is entirely unavailable.
  func read(into abl: UnsafeMutablePointer<AudioBufferList>, from: Int64, to: Int64) -> Int {
    let count = to - from
    if count == 0 { return 0 }

    var location = Location(start: max(0, from), end: max(0, from) + count)
    let original = location

    let bounds = currentBounds()
    if location.start > bounds.end || location.end < bounds.start {
      location.start = bounds.start
      location.end = bounds.start
    } else {
      location.start = max(location.start, bounds.start)
      location.end = min(location.end, bounds.end)
      location.end = max(location.start, location.end)
    }

    if location.start == location.end {
      zeroABL(abl, 0, count)
      return 0
    }

    let destinationOffset = max(0, location.start - original.start)
    if destinationOffset > 0 {
      zeroABL(abl, 0, min(count, destinationOffset))
    }
    let tailGap = max(0, original.end - location.end)
    if tailGap > 0 {
      zeroABL(abl, destinationOffset + (location.end - location.start), tailGap)
    }

    let sourceStart = location.start % Int64(capacity)
    let sourceEnd = location.end % Int64(capacity)

    if sourceStart < sourceEnd {
      fetch(abl, sourceOffset: sourceStart, offset: destinationOffset, count: sourceEnd - sourceStart)
    } else {
      let firstCount = Int64(capacity) - sourceStart
      fetch(abl, sourceOffset: sourceStart, offset: destinationOffset, count: firstCount)
      if sourceEnd > 0 {
        fetch(abl, sourceOffset: 0, offset: destinationOffset + firstCount, count: sourceEnd)
      }
    }
    return 0
  }

  private func fetch(_ abl: UnsafeMutablePointer<AudioBufferList>, sourceOffset: Int64,
                     offset: Int64, count: Int64) {
    let list = UnsafeMutableAudioBufferListPointer(abl)
    for channel in 0..<list.count {
      let buffer = list[channel]
      guard let data = buffer.mData else { continue }
      let destination = data.assumingMemoryBound(to: Float32.self)
      let channelCapacity = Int64(buffer.mDataByteSize) / 4
      if offset > channelCapacity { continue }
      let count = min(count, channelCapacity - offset)
      if channel < channels {
        let source = storage[channel].advanced(by: Int(sourceOffset))
        destination.advanced(by: Int(offset)).assign(from: source, count: Int(count))
      } else {
        destination.advanced(by: Int(offset)).initialize(repeating: 0, count: Int(count))
      }
    }
  }

  private func zeroABL(_ abl: UnsafeMutablePointer<AudioBufferList>, _ offset: Int64, _ count: Int64) {
    let list = UnsafeMutableAudioBufferListPointer(abl)
    for channel in 0..<list.count {
      guard let data = list[channel].mData else { continue }
      let destination = data.assumingMemoryBound(to: Float32.self)
      let channelCapacity = Int64(list[channel].mDataByteSize) / 4
      let bounded = min(count, channelCapacity - offset)
      if bounded > 0 {
        destination.advanced(by: Int(offset)).initialize(repeating: 0, count: Int(bounded))
      }
    }
  }

  deinit {
    for pointer in storage {
      pointer.deinitialize(count: capacity)
      pointer.deallocate()
    }
  }
}

// MARK: - Audio controller

var audioController: AudioController?

final class AudioController {
  private(set) var driverID: AudioDeviceID = 0
  private(set) var outputID: AudioDeviceID = 0
  private var driverRate: Double = 48000
  private var outputRate: Double = 48000

  var ring: RingBuffer!
  // Device-tap capture state: a tap on the virtual device's OUTPUT mix feeds
  // a private aggregate whose input we read. No input-scope client exists, so
  // macOS never classifies EqVol as microphone use (no orange mic indicator).
  var captureTapID: AudioObjectID = 0
  var captureAggID: AudioDeviceID = 0
  var captureProcID: AudioDeviceIOProcID?
  private(set) var captureRunning = false
  private var deinterleaveScratch: [UnsafeMutablePointer<Float32>]?
  var captureLastSampleTime: Double = -1
  // Diagnostics (benign races: counters only)
  var captureFrames: Int64 = 0
  var capturePeak: Float = 0
  var outputPulls: Int64 = 0
  var outputPeak: Float = 0
  var lastReadFrom: Int64 = 0
  var lastReadTo: Int64 = 0
  var boost: Float = 1.0
  private var statsTimer: DispatchSourceTimer?

  private let outputEngine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let varispeed = AVAudioUnitVarispeed()
  private let gainMixer = AVAudioMixerNode()
  var outputLastSampleTime: Double = -1
  var safetyOffset: Double = 0
  var sampleOffset: Double = 0

  private var integral: Double = 0
  private var prevError: Double = 0
  private var initialRate: Float = 1
  private var lowestRate: Float = 1
  private var highestRate: Float = 1
  private var pidTimer: DispatchSourceTimer?
  private var nodesAttached = false

  private let pidCyclesPerSecond = 10

  var isRunning: Bool { captureRunning }

  func start(targetDevice: AudioDeviceID) throws {
    guard let driver = CA.deviceByUID(DRIVER_DEVICE_UID) else {
      throw NSError(domain: "eqvol", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "eqvol.driver device not found (UID lookup failed)"])
    }
    driverID = driver
    outputID = targetDevice
    NSLog("eqvol: driver id=%d output id=%d", driverID, outputID)

    // Capture: device tap on the virtual device's OUTPUT mix -> private
    // aggregate -> IOProc into the ring. No input-scope client is opened, so
    // macOS never classifies EqVol as microphone use (no orange mic).
    // Created FIRST — mirroring the standalone probe that works: the tap is
    // this process's first audio operation, against a settled device.
    ring = RingBuffer(channels: 2, capacity: 96000)   // 2 s at 48 kHz
    try startTapCapture()
    captureRunning = true

    CA.setDriverShown(driverID, true)
    CA.setDriverName(driverID, "\(CA.deviceName(outputID)) (eqVol)")
    NSLog("eqvol: driver unhidden + renamed")

    driverRate = CA.nominalSampleRate(driverID)
    outputRate = CA.nominalSampleRate(outputID)
    NSLog("eqvol: rates driver=%.0f output=%.0f", driverRate, outputRate)

    // Try to match the driver's rate to the output device so varispeed sits ~1.0
    if driverRate != outputRate {
      _ = CA.setNominalSampleRate(driverID, outputRate)
      driverRate = CA.nominalSampleRate(driverID)
      NSLog("eqvol: matched driver rate to %.0f", driverRate)
    }

    // Route system audio into the virtual device.
    CA.setDefaultOutputDevice(driverID)
    NSLog("eqvol: default output set to driver")

    try buildOutputEngine()

    startPID()
    applyVolume()
    startStats()
  }

  private func startStats() {
    statsTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.setEventHandler { [weak self] in
      guard let self, self.captureRunning else { return }
      let bounds = self.ring.currentBoundsForDiagnostics()
      if ProcessInfo.processInfo.environment["EQVOL_STATS"] == nil { return }
      NSLog("eqvol: stats frames=%lld capPeak=%.4f outPeak=%.4f gain=%.2f rate=%.4f ring=[%lld,%lld] read=[%lld,%lld] off=%.0f saf=%.0f pulls=%lld outRunning=%d",
            self.captureFrames, self.capturePeak, self.outputPeak, self.gainMixer.outputVolume,
            self.varispeed.rate, bounds.start, bounds.end,
            self.lastReadFrom, self.lastReadTo,
            self.sampleOffset, self.safetyOffset,
            self.outputPulls, self.outputEngine.isRunning ? 1 : 0)
      self.capturePeak = 0
      self.outputPeak = 0
    }
    timer.schedule(deadline: .now() + 2, repeating: 2)
    timer.resume()
    statsTimer = timer
  }

  func stop() {
    statsTimer?.cancel()
    statsTimer = nil
    pidTimer?.cancel()
    pidTimer = nil
    outputEngine.stop()
    teardownTapCapture()
    captureRunning = false
    // Only clean up system state if the driver device is still the one we
    // captured (IDs get reused across coreaudiod restarts).
    if driverID != 0, let current = CA.deviceByUID(DRIVER_DEVICE_UID), current == driverID {
      if outputID != 0 {
        CA.setDefaultOutputDevice(outputID)
      }
      CA.setDriverShown(driverID, false)
    }
  }

  /// User picked a different output device in Sound preferences — adopt it.
  func adoptOutput(device newDevice: AudioDeviceID) {
    guard newDevice != driverID, newDevice != 0 else { return }
    outputEngine.stop()
    outputID = newDevice
    outputRate = CA.nominalSampleRate(newDevice)
    do {
      try buildOutputEngine()
    } catch {
      NSLog("eqvol: failed to adopt output %@: %@", CA.deviceName(newDevice), "\(error)")
    }
  }

  private func buildOutputEngine() throws {
    outputRate = CA.nominalSampleRate(outputID)

    if nodesAttached {
      outputEngine.detach(gainMixer)
      outputEngine.detach(varispeed)
      outputEngine.reset()
    }
    nodesAttached = true

    outputEngine.attach(player)
    outputEngine.attach(varispeed)
    outputEngine.attach(gainMixer)

    var device = outputID
    AudioUnitSetProperty(outputEngine.outputNode.audioUnit!,
                         kAudioOutputUnitProperty_CurrentDevice,
                         kAudioUnitScope_Output, 0,
                         &device, UInt32(MemoryLayout<AudioDeviceID>.size))

    // Ground truth: the driver's nominal rate can lag its actual IO rate
    // (nominal change is async and may not stick). Use the capture engine's
    // live input format for the varispeed base, else the ring drifts.
    var actualDriverRate = driverRate
    if captureAggID != 0 {
      var asbd = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                               mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
      if AudioObjectGetPropertyData(captureAggID, &fmtAddr, 0, nil, &size, &asbd) == noErr,
         asbd.mSampleRate > 0 {
        actualDriverRate = asbd.mSampleRate
      }
    }
    if actualDriverRate > 0 && actualDriverRate != driverRate {
      NSLog("eqvol: nominal driver rate %.0f but actual IO %.0f, using actual",
            driverRate, actualDriverRate)
      driverRate = actualDriverRate
    }
    let format = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
    varispeed.rate = Float(driverRate / outputRate)
    initialRate = varispeed.rate
    let bounds = 0.002
    lowestRate = initialRate * Float(1.0 - bounds)
    highestRate = initialRate * Float(1.0 + bounds)

    outputEngine.connect(player, to: varispeed, format: format)
    outputEngine.connect(varispeed, to: gainMixer, format: format)
    outputEngine.connect(gainMixer, to: outputEngine.mainMixerNode, format: format)

    var callback = AURenderCallbackStruct(inputProc: outputRenderCallback, inputProcRefCon: nil)
    AudioUnitSetProperty(varispeed.audioUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0,
                         &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

    outputLastSampleTime = -1
    integral = 0
    prevError = 0

    outputEngine.prepare()
    try outputEngine.start()
    NSLog("eqvol: output engine started")
  }

  // MARK: gain

  func applyVolume() {
    guard driverID != 0 else { return }
    let muted = CA.getMute(on: driverID) == true
    let volume = CA.getVolume(on: driverID) ?? 0
    gainMixer.outputVolume = muted ? 0 : min(Float(volume) * boost, 16.0)
    gainMixer.pan = 0
  }

  // MARK: capture (virtual device output mix -> tap -> aggregate -> ring)

  private func startTapCapture() throws {
    let tapDesc = CATapDescription(__excludingProcesses: [] as [NSNumber],
                                   andDeviceUID: DRIVER_DEVICE_UID as String,
                                   withStream: 0)
    tapDesc.muteBehavior = .unmuted
    tapDesc.isPrivate = false   // capture everything, not just this process
    var tapID = AudioObjectID(0)
    let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &tapID)
    guard tapStatus == noErr, tapID != 0 else {
      throw NSError(domain: "eqvol", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateProcessTap failed: \(tapStatus)"])
    }
    captureTapID = tapID

    var fmt = AudioStreamBasicDescription()
    var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var faddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                           mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(tapID, &faddr, 0, nil, &fsz, &fmt) == noErr {
      NSLog("eqvol: tap format: %u ch, %.0f Hz", fmt.mChannelsPerFrame, fmt.mSampleRate)
    }

    var tapUID: CFString?
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    let uidStatus = AudioObjectGetPropertyData(tapID, &uidAddr, 0, nil, &uidSize, &tapUID)
    guard uidStatus == noErr, let tuid = tapUID as String? else {
      teardownTapCapture()
      throw NSError(domain: "eqvol", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "kAudioTapPropertyUID failed: \(uidStatus)"])
    }

    let aggDict: [String: Any] = [
      "uid": "eqvol-capture-\(Int(Date().timeIntervalSince1970 * 1000))",
      "name": "eqVol capture",
      "private": true,
      "master": tuid,
      "subdevices": [["uid": tuid]],
      "taps": [["uid": tuid]],
    ]
    var aggID = AudioDeviceID(0)
    let aggStatus = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
    guard aggStatus == noErr, aggID != 0 else {
      teardownTapCapture()
      throw NSError(domain: "eqvol", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "AudioHardwareCreateAggregateDevice failed: \(aggStatus)"])
    }
    captureAggID = aggID

    var asbd = AudioStreamBasicDescription()
    var fmtSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                             mScope: kAudioObjectPropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(aggID, &fmtAddr, 0, nil, &fmtSize, &asbd) == noErr {
      NSLog("eqvol: capture stream format: %u ch, %.0f Hz, flags=0x%x nonInterleaved=%d",
            asbd.mChannelsPerFrame, asbd.mSampleRate, asbd.mFormatFlags,
            (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0 ? 1 : 0)
    }

    var proc: AudioDeviceIOProcID?
    let procStatus = AudioDeviceCreateIOProcID(aggID, captureIOCallback, nil, &proc)
    guard procStatus == noErr, proc != nil else {
      teardownTapCapture()
      throw NSError(domain: "eqvol", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "AudioDeviceCreateIOProcID failed: \(procStatus)"])
    }
    captureProcID = proc

    let startStatus = AudioDeviceStart(aggID, proc!)

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self, self.captureAggID == aggID else { return }
      var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                            mScope: kAudioObjectPropertyScopeInput,
                                            mElement: kAudioObjectPropertyElementMain)
      var sz: UInt32 = 0
      if AudioObjectGetPropertyDataSize(aggID, &addr, 0, nil, &sz) == noErr {
        let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
        if AudioObjectGetPropertyData(aggID, &addr, 0, nil, &sz, buf) == noErr {
          let bl = UnsafeMutableAudioBufferListPointer(buf)
          let chans = (0..<bl.count).map { bl[$0].mNumberChannels }
          NSLog("eqvol: agg input config (self): %u buffers, channels=%@", bl.count, chans.map(String.init).joined(separator: ","))
        }
        buf.deallocate()
      }
    }
    guard startStatus == noErr else {
      teardownTapCapture()
      throw NSError(domain: "eqvol", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "AudioDeviceStart (tap aggregate) failed: \(startStatus)"])
    }
    NSLog("eqvol: capture tap started tap=%d agg=%d", tapID, aggID)
  }

  func teardownTapCapture() {
    if let proc = captureProcID, captureAggID != 0 {
      AudioDeviceStop(captureAggID, proc)
      AudioDeviceDestroyIOProcID(captureAggID, proc)
    }
    captureProcID = nil
    if captureAggID != 0 { AudioHardwareDestroyAggregateDevice(captureAggID) }
    captureAggID = 0
    if captureTapID != 0 { AudioHardwareDestroyProcessTap(captureTapID) }
    captureTapID = 0
  }

  func handleCaptureBuffers(_ abl: UnsafeMutablePointer<AudioBufferList>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>) {
    let list = UnsafeMutableAudioBufferListPointer(abl)
    guard list.count > 0, let firstData = list[0].mData else { return }

    // The tap's mSampleTime is NOT a continuous clock (it freezes while no
    // tap audio flows and jumps on IO restarts). The delivered data is still
    // real-time, so drive ring positions from accumulated frame counts —
    // that keeps the ring in lockstep with the output engine's clock.
    let tapBuffer = list[0]
    var frames0: Int64 = 0
    if tapBuffer.mNumberChannels > 1 {
      frames0 = Int64(tapBuffer.mDataByteSize) / Int64(4 * Int(tapBuffer.mNumberChannels))
    } else {
      frames0 = Int64(tapBuffer.mDataByteSize) / 4
    }
    if captureLastSampleTime == -1 { captureLastSampleTime = timeStamp.pointee.mSampleTime }
    captureLastSampleTime += Double(frames0)
    let start = Int64(captureLastSampleTime) - frames0

    var pointers: [UnsafePointer<Float32>] = []
    var frames: Int64 = 0
    if tapBuffer.mNumberChannels > 1 {
      // Interleaved delivery: one buffer with N channels.
      let channels = Int(tapBuffer.mNumberChannels)
      frames = Int64(tapBuffer.mDataByteSize) / Int64(4 * channels)
      guard frames > 0, frames <= 4096 else { return }
      if deinterleaveScratch == nil {
        deinterleaveScratch = (0..<channels).map { _ in
          UnsafeMutablePointer<Float32>.allocate(capacity: 4096)
        }
      }
      let src = firstData.assumingMemoryBound(to: Float32.self)
      for c in 0..<channels {
        let dst = deinterleaveScratch![c]
        var index = c
        for f in 0..<Int(frames) { dst[f] = src[index]; index += channels }
        pointers.append(UnsafePointer(dst))
      }
    } else {
      // Non-interleaved delivery: one buffer per channel.
      frames = Int64(list[0].mDataByteSize) / 4
      for index in 0..<min(2, list.count) {
        guard let channelData = list[index].mData else { return }
        pointers.append(channelData.assumingMemoryBound(to: Float32.self))
      }
    }
    guard frames > 0, !pointers.isEmpty else { return }
    ring.writeDeinterleaved(pointers, frameCount: frames, start: start)

    var peak: Float = 0
    for pointer in pointers {
      for index in 0..<Int(frames) {
        let magnitude = abs(pointer[index])
        if magnitude > peak { peak = magnitude }
      }
    }
    captureFrames += frames
    if peak > capturePeak { capturePeak = peak }
  }

  // MARK: output (ring -> varispeed -> gain -> real device)

  func computeOffset() {
    let captureDevice = captureAggID != 0 ? captureAggID : driverID
    let inputOffset = CA.safetyOffset(captureDevice, kAudioObjectPropertyScopeInput)
    let inputBuffer = CA.bufferFrameSize(captureDevice, kAudioObjectPropertyScopeInput)
    let outputOffset = CA.safetyOffset(outputID, kAudioObjectPropertyScopeOutput)
    let outputBuffer = CA.bufferFrameSize(outputID, kAudioObjectPropertyScopeOutput)
    safetyOffset = Double(inputOffset + outputOffset + inputBuffer + outputBuffer)
    sampleOffset = captureLastSampleTime - outputLastSampleTime
  }

  func resetOffsets() {
    integral = 0
    varispeed.rate = initialRate
    computeOffset()
  }

  private func startPID() {
    pidTimer?.cancel()
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    timer.setEventHandler { [weak self] in self?.computeVarispeed() }
    timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / pidCyclesPerSecond))
    timer.resume()
    pidTimer = timer
  }

  // PID controller adjusting varispeed so the ring buffer never drifts out
  // PID controller adjusting varispeed so the ring buffer never drifts.
  private func computeVarispeed() {
    guard captureRunning, outputLastSampleTime != -1, captureLastSampleTime != -1 else { return }

    let lastSafetyOffset = captureLastSampleTime - (outputLastSampleTime + sampleOffset - safetyOffset)
    var history = safetyHistory
    history.insert(lastSafetyOffset, at: 0)
    if history.count > pidCyclesPerSecond {
      history.removeLast(history.count - pidCyclesPerSecond)
    }
    safetyHistory = history
    let average = history.reduce(0, +) / Double(history.count)
    guard average > 0 else { return }

    let errorRatio = safetyOffset / average
    let error = 1.0 - errorRatio

    let kp = 0.0001
    let ki = 0.0
    let kd = 0.0001
    let dt = 1.0 / Double(pidCyclesPerSecond)

    let p = kp * error
    integral += error * dt
    let i = ki * integral
    let derivative = (error - prevError) / dt
    let d = kd * derivative
    prevError = error

    var newRate = varispeed.rate + Float(p + i + d)
    if newRate < lowestRate { newRate = lowestRate }
    if newRate > highestRate { newRate = highestRate }
    varispeed.rate = newRate
  }

  private var safetyHistory: [Double] = []
}

/// Zero every buffer in an AudioBufferList (makeBufferSilent is not exposed to Swift).
func fillSilent(_ output: UnsafeMutablePointer<AudioBufferList>) {
  let list = UnsafeMutableAudioBufferListPointer(output)
  for index in 0..<list.count {
    if let data = list[index].mData {
      memset(data, 0, Int(list[index].mDataByteSize))
    }
  }
}

// MARK: - C callbacks (no captures; reach state through the global)

let captureIOCallback: AudioDeviceIOProc = { _, _, inInputData, inInputTime, _, _, _ in
  if let controller = audioController, controller.captureRunning {
    controller.handleCaptureBuffers(UnsafeMutablePointer(mutating: inInputData), inInputTime)
  }
  return noErr
}

let outputRenderCallback: AURenderCallback = { _, _, inTimeStamp, _, inNumberFrames, ioData in
  guard let controller = audioController,
        controller.captureRunning,
        controller.captureLastSampleTime != -1,
        let output = ioData else {
    if let output = ioData { fillSilent(output) }
    return noErr
  }

  let sampleTime = inTimeStamp.pointee.mSampleTime

  if controller.outputLastSampleTime == -1 {
    controller.outputLastSampleTime = sampleTime
    controller.computeOffset()
    fillSilent(output)
    return noErr
  }
  controller.outputLastSampleTime = sampleTime
  controller.outputPulls += 1

  let from = Int64(sampleTime + controller.sampleOffset - controller.safetyOffset)
  let to = from + Int64(inNumberFrames)
  controller.lastReadFrom = from
  controller.lastReadTo = to
  if controller.ring.read(into: output, from: from, to: to) != 0 {
    fillSilent(output)
    controller.resetOffsets()
    return noErr
  }
  let list = UnsafeMutableAudioBufferListPointer(output)
  var peak: Float = 0
  for bufferIndex in 0..<list.count {
    if let channelData = list[bufferIndex].mData {
      let samples = channelData.assumingMemoryBound(to: Float32.self)
      let count = Int(list[bufferIndex].mDataByteSize) / 4
      for index in 0..<count {
        let magnitude = abs(samples[index])
        if magnitude > peak { peak = magnitude }
      }
    }
  }
  if peak > controller.outputPeak { controller.outputPeak = peak }
  return noErr
}

// MARK: - Change watcher (adapted from VolumeBar; default device = virtual device)

final class VolumeWatcher {
  private let queue = DispatchQueue(label: "eqvol.watch")
  private var device: AudioDeviceID = 0
  private var watched: [(address: AudioObjectPropertyAddress,
                         block: AudioObjectPropertyListenerBlock)] = []
  var onVolumeChange: (() -> Void)?
  var onDefaultDeviceChange: ((AudioDeviceID) -> Void)?

  func start() {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.rearm()
        self.onDefaultDeviceChange?(CA.defaultOutputDevice())
      }
    }
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                        &address, queue, block)
    rearm()
  }

  private func rearm() {
    if device != 0 {
      for var entry in watched {
        AudioObjectRemovePropertyListenerBlock(device, &entry.address, queue, entry.block)
      }
      watched.removeAll()
    }
    device = CA.defaultOutputDevice()
    guard device != 0 else { return }
    for selector in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
      for element in CA.elements(on: device, selector: selector) {
        var address = AudioObjectPropertyAddress(
          mSelector: selector, mScope: kAudioObjectPropertyScopeOutput, mElement: element)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
          DispatchQueue.main.async { self?.onVolumeChange?() }
        }
        AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        watched.append((address, block))
      }
    }
  }
}

// MARK: - Menu bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var boost: Float = 1.0
  private var keepAliveWindow: NSWindow?
  private let popover = NSPopover()
  private var slider: NSSlider!
  private var percentLabel: NSTextField!
  private var muteButton: NSButton!
  private var boostSelector: NSPopUpButton!
  private let watcher = VolumeWatcher()
  private var expectingDefaultReclaim = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    // Autostart is handled by the LaunchAgent (com.jocala.eqvol) spawning the
    // launcher, NOT a Login Item: launchd-spawned bundle apps get TCC-attributed
    // and their audio taps run silent. Clear any older Login-Item registration.
    do {
      try? SMAppService.mainApp.unregister()
      NSLog("eqvol: Login Item state after unregister: \(SMAppService.mainApp.status.rawValue)")
    }
    boost = Float(UserDefaults.standard.object(forKey: "eqvol_boost") as? Float ?? 1.0)
    if boost < 1 { boost = 1 }
    // Window-less accessory apps get auto-terminated by AppKit/TAL after a
    // few seconds — that would kill the audio engine. A 1x1 offscreen window
    // keeps the app "windowed" so the Transparent App Lifecycle leaves it alone.
    ProcessInfo.processInfo.disableAutomaticTermination("eqVol audio engine is running")
    let keepAlive = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 1, height: 1),
                             styleMask: [.borderless], backing: .buffered, defer: false)
    keepAlive.isReleasedWhenClosed = false
    keepAlive.alphaValue = 0.01
    keepAlive.ignoresMouseEvents = true
    keepAlive.level = .init(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))
    keepAlive.orderFront(nil)
    keepAliveWindow = keepAlive
    buildMenuBar()
    // No microphone access anymore: capture is a device tap on the virtual
    // device's output mix, so there is no TCC prompt and no mic indicator.
    startAudioStack()
  }

  private func startAudioStack() {
    guard let driver = CA.deviceByUID(DRIVER_DEVICE_UID) else {
      showAlertAndQuit(title: "eqVol: driver missing",
                       message: "The eqVol virtual audio device (EQVolDevice) was not found.\nIs /Library/Audio/Plug-Ins/HAL/eqvol.driver installed?")
      return
    }

    // Choose the real output target: whatever is default now, unless that is
    // already the virtual device (or nothing) — then fall back to the first
    // real output device.
    let current = CA.defaultOutputDevice()
    let target: AudioDeviceID
    if current != driver, current != 0 {
      target = current
    } else if let first = CA.realOutputDevices(excluding: driver).first {
      target = first
    } else {
      showAlertAndQuit(title: "eqVol: no output device",
                       message: "No real output device found to route audio to.")
      return
    }

    do {
      let controller = AudioController()
      controller.boost = boost
      audioController = controller
      try controller.start(targetDevice: target)
    } catch {
      NSLog("eqvol: failed to start: \(error)")
      audioController = nil
      showAlertAndQuit(title: "eqVol: failed to start",
                       message: "\(error.localizedDescription)")
      return
    }

    watcher.onVolumeChange = { [weak self] in
      audioController?.applyVolume()
      self?.refresh()
    }
    watcher.onDefaultDeviceChange = { [weak self] newDefault in
      guard let self, let controller = audioController else { return }
      if self.expectingDefaultReclaim {
        self.expectingDefaultReclaim = false
        return
      }
      if newDefault != controller.driverID, newDefault != 0 {
        // User picked a new output in Sound preferences.
        self.expectingDefaultReclaim = true
        controller.adoptOutput(device: newDefault)
      }
    }
    watcher.start()
    refresh()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    audioController?.stop()
    audioController = nil
    return .terminateNow
  }

  func applicationWillTerminate(_ notification: Notification) {
    statusItem = nil
  }

  // MARK: menu bar

  private func buildMenuBar() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    popover.behavior = .transient
    popover.contentSize = NSSize(width: 240, height: 106)
    popover.contentViewController = makeContentViewController()
    let button = statusItem.button!
    button.target = self
    button.action = #selector(togglePopover(_:))
  }

  private func makeContentViewController() -> NSViewController {
    let controller = NSViewController()
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 106))

    percentLabel = NSTextField(labelWithString: "–")
    percentLabel.frame = NSRect(x: 16, y: 74, width: 70, height: 18)
    percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)

    muteButton = NSButton(title: "Mute", target: self, action: #selector(muteToggle(_:)))
    muteButton.frame = NSRect(x: 100, y: 72, width: 80, height: 22)
    muteButton.bezelStyle = .rounded

    let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit(_:)))
    quitButton.frame = NSRect(x: 192, y: 72, width: 40, height: 22)
    quitButton.bezelStyle = .rounded
    quitButton.controlSize = .small
    quitButton.font = NSFont.systemFont(ofSize: 11)

    slider = NSSlider(value: 0, minValue: 0, maxValue: 100,
                      target: self, action: #selector(sliderMoved(_:)))
    slider.frame = NSRect(x: 16, y: 36, width: 208, height: 26)
    slider.isContinuous = true

    let boostLabel = NSTextField(labelWithString: "Boost")
    boostLabel.frame = NSRect(x: 16, y: 12, width: 44, height: 14)
    boostLabel.font = NSFont.systemFont(ofSize: 10)
    boostLabel.textColor = .secondaryLabelColor

    boostSelector = NSPopUpButton(frame: NSRect(x: 64, y: 8, width: 80, height: 20),
                                  pullsDown: false)
    for option in ["100%", "150%", "200%", "300%", "400%", "600%", "800%", "1000%"] {
      boostSelector.addItem(withTitle: option)
    }
    boostSelector.target = self
    boostSelector.action = #selector(boostChanged(_:))
    boostSelector.font = NSFont.systemFont(ofSize: 10)
    let boostValues: [Float] = [1.0, 1.5, 2.0, 3.0, 4.0, 6.0, 8.0, 10.0]
    let savedIndex = boostValues.firstIndex(of: boost) ?? 0
    boostSelector.selectItem(at: savedIndex)

    container.addSubview(percentLabel)
    container.addSubview(muteButton)
    container.addSubview(quitButton)
    container.addSubview(slider)
    container.addSubview(boostLabel)
    container.addSubview(boostSelector)
    controller.view = container
    return controller
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem.button else { return }
    if popover.isShown {
      popover.performClose(sender)
    } else {
      refresh()
      NSApp.activate(ignoringOtherApps: true)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
  }

  @objc private func sliderMoved(_ sender: NSSlider) {
    guard let controller = audioController, controller.driverID != 0 else { return }
    CA.setVolume(sender.doubleValue / 100.0, on: controller.driverID)
    percentLabel.stringValue = "\(Int(sender.doubleValue))%"
  }

  @objc private func muteToggle(_ sender: NSButton) {
    guard let controller = audioController, controller.driverID != 0,
          let muted = CA.getMute(on: controller.driverID) else { return }
    CA.setMute(!muted, on: controller.driverID)
  }

  @objc private func boostChanged(_ sender: NSPopUpButton) {
    let percent = sender.titleOfSelectedItem?.dropLast() ?? "100"
    boost = Float(percent) ?? 100
    boost /= 100
    UserDefaults.standard.set(boost, forKey: "eqvol_boost")
    audioController?.boost = boost
    audioController?.applyVolume()
  }

  @objc private func quit(_ sender: Any?) {
    NSApp.terminate(sender)
  }

  private func refresh() {
    guard let controller = audioController, controller.driverID != 0 else {
      slider.isEnabled = false
      percentLabel.stringValue = "n/a"
      setMenuBarIcon(dimmed: false)
      return
    }
    let volume = CA.getVolume(on: controller.driverID)
    let mute = CA.getMute(on: controller.driverID)

    if let v = volume {
      slider.isEnabled = true
      slider.doubleValue = (v * 100).rounded()
      percentLabel.stringValue = "\(Int((v * 100).rounded()))%"
    } else {
      slider.isEnabled = false
      percentLabel.stringValue = "n/a"
    }
    muteButton.isEnabled = (mute != nil)
    muteButton.title = (mute == true) ? "Unmute" : "Mute"

    let iconName: String
    // "display": the HDMI display's audio. Deliberately NOT a speaker glyph —
    // Control Center's speaker would make two in the menu bar. Mute reads as
    // a dimmed icon.
    setMenuBarIcon(dimmed: mute == true)
  }

  private func setMenuBarIcon(dimmed: Bool) {
    statusItem.button?.image = NSImage(systemSymbolName: "display",
                                       accessibilityDescription: "eqVol volume")
    statusItem.button?.alphaValue = dimmed ? 0.45 : 1.0
  }

  private func showAlertAndQuit(title: String, message: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.runModal()
    NSApp.terminate(self)
  }
}

// MARK: - Entry point

enum PortGuard {
  static let port: in_port_t = 49092

  static var anotherInstanceRunning: Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian)
    let bound = withUnsafePointer(to: &addr) { pointer -> Int32 in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bound == 0 {
      close(fd)
      return false
    }
    return errno == EADDRINUSE
  }
}

if PortGuard.anotherInstanceRunning {
  FileHandle.standardError.write("eqvol: already running\n".data(using: .utf8)!)
  exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
