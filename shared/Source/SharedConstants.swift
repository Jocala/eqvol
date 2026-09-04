import Foundation
import CoreAudio.AudioServerPlugIn

public let APP_BUNDLE_ID = "com.jocala.eqvol"
public let DRIVER_BUNDLE_ID = "com.jocala.eqvol.driver"

public struct EQVDeviceCustomProperties: Loopable {
  public let version = AudioObjectPropertySelector.fromString("vrsn")
  public let shown = AudioObjectPropertySelector.fromString("shwn")
  public let latency = AudioObjectPropertySelector.fromString("cltc")
  public let name = AudioObjectPropertySelector.fromString("eqvn")

  public var count: UInt32 {
    return UInt32(properties.count)
  }
}

public struct EQVDeviceCustomAddresses {
  public var version = AudioObjectPropertyAddress(
    mSelector: EQVDeviceCustom.properties.version,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMaster
  )

  public var shown = AudioObjectPropertyAddress(
    mSelector: EQVDeviceCustom.properties.shown,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMaster
  )

  public var latency = AudioObjectPropertyAddress(
    mSelector: EQVDeviceCustom.properties.latency,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMaster
  )

  public var name = AudioObjectPropertyAddress(
    mSelector: EQVDeviceCustom.properties.name,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMaster
  )
}

public struct EQVDeviceCustom {
  public static let properties = EQVDeviceCustomProperties()
  public static var addresses = EQVDeviceCustomAddresses()
}

public let kEQVDeviceSupportedSampleRates: [Float64] = [
  44_100,
  48_000,
  88_200,
  96_000,
  176_400,
  192_000
]

public let kMinVolumeDB: Float32 = -96
public let kMaxVolumeDB: Float32 = 0
