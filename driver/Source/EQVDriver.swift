//
// EQVDriver.swift
//  eqVol
//


//

import Foundation
import CoreAudio.AudioServerPlugIn
import Atomics
import Shared

@objc class EQVDriver: NSObject {
  static var host: AudioServerPlugInHostRef?
  static var hostTicksPerFrame: Float64?
  
  static private var _interface: AudioServerPlugInDriverInterface?
  static private var _interfacePtr: UnsafeMutablePointer<AudioServerPlugInDriverInterface>?
  
  static var refCounter = ManagedAtomic<UInt32>(0)
  @objc public static var ref: AudioServerPlugInDriverRef?

  static var mutex = Mutex()
  
  @objc
  public static func create (allocator: CFAllocator!, requestedTypeUUID: CFUUID!) -> UnsafeMutableRawPointer? {
    // This is the CFPlugIn factory function. Its job is to create the implementation for the given
    // type provided that the type is supported. Because this driver is simple and all its
    // initialization is handled via static iniitalization when the bundle is loaded, all that
    // needs to be done is to return the AudioServerPlugInDriverRef that points to the driver's
    // interface. A more complicated driver would create any base line objects it needs to satisfy
    // the IUnknown methods that are used to discover that actual interface to talk to the driver.
    // The majority of the driver's initilization should be handled in the Initialize() method of
    // the driver's AudioServerPlugInDriverInterface.
    
    if !CFEqual(requestedTypeUUID, kAudioServerPluginTypeUUID) {
      return nil
    }
    
    return UnsafeMutableRawPointer(createRef())
  }
  
  private static func createRef () -> AudioServerPlugInDriverRef {
    if ref != nil {
      return ref!
    }
    
    _interface = AudioServerPlugInDriverInterface(
      _reserved: nil,
      QueryInterface: EQV_QueryInterface,
      AddRef: EQV_AddRef,
      Release: EQV_Release,
      Initialize: EQV_Initialize,
      CreateDevice: EQV_CreateDevice,
      DestroyDevice: EQV_DestroyDevice,
      AddDeviceClient: EQV_AddDeviceClient,
      RemoveDeviceClient: EQV_RemoveDeviceClient,
      PerformDeviceConfigurationChange: EQV_PerformDeviceConfigurationChange,
      AbortDeviceConfigurationChange: EQV_AbortDeviceConfigurationChange,
      HasProperty: EQV_HasProperty,
      IsPropertySettable: EQV_IsPropertySettable,
      GetPropertyDataSize: EQV_GetPropertyDataSize,
      GetPropertyData: EQV_GetPropertyData,
      SetPropertyData: EQV_SetPropertyData,
      StartIO: EQV_StartIO,
      StopIO: EQV_StopIO,
      GetZeroTimeStamp: EQV_GetZeroTimeStamp,
      WillDoIOOperation: EQV_WillDoIOOperation,
      BeginIOOperation: EQV_BeginIOOperation,
      DoIOOperation: EQV_DoIOOperation,
      EndIOOperation: EQV_EndIOOperation
    )
    
    _interfacePtr = withUnsafeMutablePointer(to: &_interface!) { $0 }
    ref = withUnsafeMutablePointer(to: &_interfacePtr) { $0 }
    
    return ref!
  }
  
  static func validateDriver (_ driverPointer: UnsafeMutableRawPointer?, reference: AudioServerPlugInDriverRef = EQVDriver.ref!) -> Bool {
    guard driverPointer != nil else { return false }
    let driver = driverPointer!.assumingMemoryBound(to: (UnsafeMutablePointer<AudioServerPlugInDriverInterface>?).self)
    let valid = reference == driver
    return valid
  }

  static func validateObject (_ objectID: AudioObjectID) -> Bool {
    if getEQVObject(from: objectID) != nil {
      return true
    }
    log("Invalid object for ID: \(objectID)")
    return false
  }

  static func getEQVObject(from objectID: AudioObjectID) -> EQVObject.Type? {
    switch objectID {
    case kObjectID_PlugIn: return EQVPlugIn.self
    case kObjectID_Device: return EQVDevice.self
    case kObjectID_Stream_Input,
         kObjectID_Stream_Output: return EQVStream.self
    case kObjectID_Volume_Output_Master,
         kObjectID_Mute_Output_Master,
         kObjectID_DataSource_Output_Master: return EQVControl.self
    default: return nil
    }
  }
  
  static func getEQVObjectClassName (from objectID: AudioObjectID) -> String {
    switch objectID {
    case kObjectID_PlugIn: return "🟢 PlugIn"
    case kObjectID_Device: return "​🔴​​ Device"
    case kObjectID_Stream_Input,
         kObjectID_Stream_Output: return "🟠 Stream"
    case kObjectID_Volume_Output_Master,
         kObjectID_Mute_Output_Master,
         kObjectID_DataSource_Output_Master: return "🔵​ Control"
    default: return "⚫️ Unknown"
    }
  }
  
  static func calculateHostTicksPerFrame () {
    // calculate the host ticks per frame
    var theTimeBaseInfo = mach_timebase_info()
    mach_timebase_info(&theTimeBaseInfo)
    var theHostClockFrequency = Float64(theTimeBaseInfo.denom) / Float64(theTimeBaseInfo.numer)
    theHostClockFrequency *= 1000000000.0
    hostTicksPerFrame = theHostClockFrequency / EQVDevice.sampleRate
  }

  static func propertiesUpdated (objectId: AudioObjectID, changedProperties: [AudioObjectPropertyAddress]) {
    guard let host = host, changedProperties.count > 0 else {
      return
    }
    _ = host.pointee.PropertiesChanged(
      host,
      objectId,
      UInt32(changedProperties.count),
      changedProperties
    )
  }
}
