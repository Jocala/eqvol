//
// EQVInterface.swift
//  eqVol
//


//

import Foundation
import CoreAudio.AudioServerPlugIn
import Shared

// MARK: - Inheritance
func EQV_QueryInterface (
  inDriver: UnsafeMutableRawPointer?,
  inUUID: REFIID,
  outInterface: UnsafeMutablePointer<LPVOID?>?
) -> HRESULT {
  // This function is called by the HAL to get the interface to talk to the plug-in through.
  // AudioServerPlugIns are required to support the IUnknown interface and the
  // AudioServerPlugInDriverInterface. As it happens, all interfaces must also provide the
  // IUnknown interface, so we can always just return the single interface we made with
  // gAudioServerPlugInDriverInterfacePtr regardless of which one is asked for.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  
  // log("Invoked EQV_QueryInterface()")
  let uuid = CFUUIDCreateFromUUIDBytes(nil, inUUID)
  if uuid == nil || outInterface == nil {
    return kAudioHardwareIllegalOperationError
  }
  
  guard CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPluginDriverInterfaceUUID) else { return HRESULT.noInterface }
  
  EQVDriver.refCounter.wrappingIncrement(ordering: .relaxed)
  outInterface!.pointee = UnsafeMutableRawPointer(EQVDriver.ref)
  
  // log("EQV_QueryInterface() -> \(String(describing: EQVDriver.ref))")
  
  return HRESULT.ok
}

func EQV_AddRef (inDriver: UnsafeMutableRawPointer?) -> ULONG {
  // This call returns the resulting reference count after the increment.
  guard EQVDriver.validateDriver(inDriver) else { return ULONG(kAudioHardwareBadObjectError) }
  // log("Invoked EQV_AddRef()")
  
  return EQVDriver.refCounter.wrappingIncrementThenLoad(ordering: .relaxed)
}

func EQV_Release (inDriver: UnsafeMutableRawPointer?) -> ULONG {
  // This call returns the resulting reference count after the decrement.
  guard EQVDriver.validateDriver(inDriver) else { return ULONG(kAudioHardwareBadObjectError) }
  // log("Invoked EQV_Release()")
  return EQVDriver.refCounter.wrappingDecrementThenLoad(ordering: .relaxed)
}

// MARK: - Basic Operations
func EQV_Initialize (inDriver: AudioServerPlugInDriverRef, inHost: AudioServerPlugInHostRef) -> OSStatus {
  // This method is called to initialize the instance of the plug-in.
  // The job of this method is, as the name implies, to get the driver initialized. One specific
  // thing that needs to be done is to store the AudioServerPlugInHostRef so that it can be used
  // later. Note that when this call returns, the HAL will scan the various lists the driver
  // maintains (such as the device list) to get the inital set of objects the driver is
  // publishing. So, there is no need to notifiy the HAL about any objects created as part of the
  // execution of this method.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  
  // log("Invoked EQV_Initialize()")

  EQVDriver.host = inHost

  EQVDriver.calculateHostTicksPerFrame()
  NSLog("EQVDIAG: plugin initialized, shown=\(EQVDevice.shown) rate=\(EQVDevice.sampleRate)")

  // log("EQV_Initialize() - Host: \(String(describing: EQVDriver.host)) | hostTicksPerFrame = \(String(describing: EQVDriver.hostTicksPerFrame))")

  return noErr
}

func EQV_CreateDevice (
  inDriver: AudioServerPlugInDriverRef,
  inDescription: CFDictionary,
  inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>,
  outDeviceObjectID: UnsafeMutablePointer<AudioObjectID>
) -> OSStatus {
  // Tells the plug-in to create a new device based on the given description.
  // This method is used to tell a driver that implements the Transport Manager semantics to
  // create an AudioEndpointDevice from a set of AudioEndpoints. Since this driver is not a
  // Transport Manager, we just check the arguments and return
  // kAudioHardwareUnsupportedOperationError.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return kAudioHardwareUnsupportedOperationError
}

func EQV_DestroyDevice (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID) -> OSStatus {
  // Called to tell the plug-in about to destroy the given device.
  // This method is used to tell a driver that implements the Transport Manager semantics to
  // destroy an AudioEndpointDevice. Since this driver is not a Transport Manager, we just check
  // the arguments and return kAudioHardwareUnsupportedOperationError.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return kAudioHardwareUnsupportedOperationError
}

func EQV_AddDeviceClient (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>) -> OSStatus {
  // Called to tell the plug-in about a new client of the Host for a particular device.
  // This method is used to inform the driver about a new client that is using the given device.
  // This allows the device to act differently depending on who the client is. This driver does
  // not need to track the clients using the device, so we just check the arguments and return
  // successfully.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  EQVClients.add(EQVClient(from: inClientInfo.pointee))

  return noErr
}

func EQV_RemoveDeviceClient (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientInfo: UnsafePointer<AudioServerPlugInClientInfo>) -> OSStatus {
  // Called to tell the plug-in about a client that is no longer using the device.
  // This method is used to inform the driver about a client that is no longer using the given
  // device. This driver does not track clients, so we just check the arguments and return
  // successfully.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  let client = EQVClient(from: inClientInfo.pointee)
  EQVClients.remove(client)

  if (client.isAppClient && !EQVClients.isAppClientPresent) {
    EQVDevice.shown = false
  }

  return noErr
}

func EQV_PerformDeviceConfigurationChange (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inChangeAction: UInt64,
  inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called by the Host to allow the device to perform a configuration change that had been previously requested via a call to the Host method, RequestDeviceConfigurationChange().
  // This method is called to tell the device that it can perform the configuation change that it
  // had requested via a call to the host method, RequestDeviceConfigurationChange(). The
  // arguments, inChangeAction and inChangeInfo are the same as what was passed to
  // RequestDeviceConfigurationChange().
  //
  // The HAL guarantees that IO will be stopped while this method is in progress. The HAL will
  // also handle figuring out exactly what changed for the non-control related properties. This
  // means that the only notifications that would need to be sent here would be for either
  // custom properties the HAL doesn't know about or for controls.
  //
  // For the device implemented by this driver, only sample rate changes go through this process
  // as it is the only state that can be changed for the device that isn't a control. For this
  // change, the new sample rate is passed in the inChangeAction argument.
  
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
//  log("Invoked EQV_PerformDeviceConfigurationChange()")
  if !kEQVDeviceSupportedSampleRates.contains(where: { UInt64($0) == inChangeAction }) { return kAudioHardwareBadObjectError }

  EQVDriver.mutex.lock()
  
  EQVDevice.sampleRate = Float64(inChangeAction)
  EQVDriver.calculateHostTicksPerFrame()

  EQVDriver.mutex.unlock()
//  log("EQV_PerformDeviceConfigurationChange() - EQVDevice.sampleRate = \(EQVDevice.sampleRate) | hostTicksPerFrame = \(String(describing: EQVDriver.hostTicksPerFrame))")

  return noErr
}

func EQV_AbortDeviceConfigurationChange (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inChangeAction: UInt64,
  inChangeInfo: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called by the Host to tell the plug-in not to perform a configuration change that had been requested via a call to the Host method, RequestDeviceConfigurationChange().
  // This method is called to tell the driver that a request for a config change has been denied.
  // This provides the driver an opportunity to clean up any state associated with the request.
  // For this driver, an aborted config change requires no action. So we just check the arguments
  // and return
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  return noErr
}

// MARK: - Property Operations
// Note that for each object, this driver implements all the required properties plus a few
// extras that are useful but not required. There is more detailed commentary about each
// property in the EQVPlugin.getPropertyData() and EQVDevice.getPropertyData() methods.

func EQV_HasProperty (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>
) -> DarwinBoolean {
  // This method returns whether or not the given object has the given property.
  let address = inAddress.pointee

  // log("Invoking: \(EQVDriver.getEQVObjectClassName(from: inObjectID)).hasProperty(\(propertyName(address.mSelector)))")
  let hasProperty: Bool = ({
    guard EQVDriver.validateDriver(inDriver) else { return false }
    if let obj = EQVDriver.getEQVObject(from: inObjectID) {
      return obj.hasProperty(objectID: inObjectID, address: address)
    } else {
      return false
    }
  })()
//  log("\(EQVDriver.getEQVObjectClassName(from: inObjectID)).hasProperty(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(hasProperty)")

  return DarwinBoolean(hasProperty)
}

func EQV_IsPropertySettable (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  outIsSettable: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
  let address = inAddress.pointee
  // This method returns whether or not the given property on the object can have its value changed.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  
  // log("Invoking: \(EQVDriver.getEQVObjectClassName(from: inObjectID)).isPropertySettable(\(propertyName(inAddress.pointee.mSelector)))")
  let isSettable = DarwinBoolean(({
    if let obj = EQVDriver.getEQVObject(from: inObjectID) {
      return obj.isPropertySettable(objectID: inObjectID, address: address)
    } else {
      return false
    }
  })())
//  log("\(EQVDriver.getEQVObjectClassName(from: inObjectID)).getPropertySettable(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(isSettable)")

  outIsSettable.pointee = isSettable
  
  return noErr
}

func EQV_GetPropertyDataSize (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  outDataSize: UnsafeMutablePointer<UInt32>
) -> OSStatus {
  let address = inAddress.pointee

  // This method returns the byte size of the property's data.
  guard EQVDriver.validateDriver(inDriver) && EQVDriver.validateObject(inObjectID) else { return kAudioHardwareBadObjectError }
  
  let size = ({ () -> UInt32? in
    if let obj = EQVDriver.getEQVObject(from: inObjectID) {
      return obj.getPropertyDataSize(objectID: inObjectID, address: address)
    } else {
      return nil
    }
  })()
  log("\(EQVDriver.getEQVObjectClassName(from: inObjectID)).getPropertyDataSize(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(size ?? 0)")

  if size != nil {
    outDataSize.pointee = size!
    return noErr
  } else {
    return kAudioHardwareUnknownPropertyError
  }
}

func EQV_GetPropertyData (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  inDataSize: UInt32,
  outDataSize: UnsafeMutablePointer<UInt32>,
  outData: UnsafeMutableRawPointer
) -> OSStatus {
  let address = inAddress.pointee

  // Fetches the data of the given property and places it in the provided buffer.
  guard EQVDriver.validateDriver(inDriver) && EQVDriver.validateObject(inObjectID) else {
//    log("Invalid driver or object id while in EQV_GetPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))")
    return kAudioHardwareBadObjectError
  }

   log("Invoking: \(EQVDriver.getEQVObjectClassName(from: inObjectID)).getPropertyData(\(propertyName(inAddress.pointee.mSelector))) - Size requested: \(inDataSize)")
  
  let data = ({ () -> EQVObjectProperty? in
    if let obj = EQVDriver.getEQVObject(from: inObjectID) {
      return obj.getPropertyData(objectID: inObjectID, address: address, inData: inQualifierData)
    } else {
      return nil
    }
  })()
  log("\(EQVDriver.getEQVObjectClassName(from: inObjectID)).getPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) - Size requested: \(inDataSize) = \(String(describing: data))")
  if data != nil {
    let status = data!.write(to: outData, size: outDataSize, requestedSize: inDataSize)
    return status
  } else {
    outDataSize.pointee = 0
    return kAudioHardwareUnknownPropertyError
  }
}

func EQV_SetPropertyData (
  inDriver: AudioServerPlugInDriverRef,
  inObjectID: AudioObjectID,
  inClientProcessID: pid_t,
  inAddress: UnsafePointer<AudioObjectPropertyAddress>,
  inQualifierDataSize: UInt32,
  inQualifierData: UnsafeRawPointer?,
  inDataSize: UInt32,
  inData: UnsafeRawPointer
) -> OSStatus {
  let address = inAddress.pointee
  // Tells an object to change the value of the given property.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }
  
  log("PID(\(inClientProcessID)) \(EQVDriver.getEQVObjectClassName(from: inObjectID)).setPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) = \(String(describing: inData))")

  if let obj = EQVDriver.getEQVObject(from: inObjectID) {
    var changedProperties: [AudioObjectPropertyAddress] = []
    let status = obj.setPropertyData(
      client: EQVClients.get(processId: inClientProcessID),
      objectID: inObjectID,
      address: address,
      data: inData,
      changedProperties: &changedProperties
    )
    
    EQVDriver.propertiesUpdated(objectId: inObjectID, changedProperties: changedProperties)

    log("\(EQVDriver.getEQVObjectClassName(from: inObjectID)).setPropertyData(\(propertyName(address.mSelector)), \(scopeName(address.mScope))) - Status: \(status) - Changed Properties: \(changedProperties)")

    return status
  } else {
    return kAudioHardwareBadObjectError
  }
}

// MARK: - IO Operations
func EQV_StartIO (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientID: UInt32) -> OSStatus {
  // This call tells the device that IO is starting for the given client. When this routine
  // returns, the device's clock is running and it is ready to have data read/written. It is
  // important to note that multiple clients can have IO running on the device at the same time.
  // So, work only needs to be done when the first client starts. All subsequent starts simply
  // increment the counter.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  EQVDriver.mutex.lock()
  let status = EQVDevice.startIO()
  EQVDriver.mutex.unlock()

  return status
}

func EQV_StopIO (inDriver: AudioServerPlugInDriverRef, inDeviceObjectID: AudioObjectID, inClientID: UInt32) -> OSStatus {
  // This call tells the device that the client has stopped IO. The driver can stop the hardware
  // once all clients have stopped.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  EQVDriver.mutex.lock()
  let status = EQVDevice.stopIO()
  EQVDriver.mutex.unlock()
  
  return status
}

func EQV_GetZeroTimeStamp (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  outSampleTime: UnsafeMutablePointer<Float64>,
  outHostTime: UnsafeMutablePointer<UInt64>,
  outSeed: UnsafeMutablePointer<UInt64>
) -> OSStatus {
  // This method returns the current zero time stamp for the device. The HAL models the timing of
  // a device as a series of time stamps that relate the sample time to a host time. The zero
  // time stamps are spaced such that the sample times are the value of
  // kAudioDevicePropertyZeroTimeStampPeriod apart. This is often modeled using a ring buffer
  // where the zero time stamp is updated when wrapping around the ring buffer.
  //
  // For this device, the zero time stamps' sample time increments every kDevice_RingBufferSize
  // frames and the host time increments by kDevice_RingBufferSize * gDevice_HostTicksPerFrame.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  let status = EQVDevice.getZeroTimeStamp(
    outSampleTime: outSampleTime,
    outHostTime: outHostTime,
    outSeed: outSeed
  )

  return status
}

func EQV_WillDoIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  outWillDo: UnsafeMutablePointer<DarwinBoolean>,
  outWillDoInPlace: UnsafeMutablePointer<DarwinBoolean>
) -> OSStatus {
  // Asks the plug-in whether or not the device will perform the given phase of the IO cycle for a particular device.
  // This method returns whether or not the device will do a given IO operation. For this device,
  // we only support reading input data and writing output data.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  var willDo = false
  var willDoInPlace = true
  
  switch inOperationID {
  case AudioServerPlugInIOOperation.writeMix.rawValue:
    willDo = true
    willDoInPlace = true
    break
  case AudioServerPlugInIOOperation.readInput.rawValue:
    willDo = true
    willDoInPlace = true
    break
  default: break
  }
  
  outWillDo.pointee = DarwinBoolean(willDo)
  outWillDoInPlace.pointee = DarwinBoolean(willDoInPlace)

  return noErr
}

func EQV_BeginIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
  // Tells the plug-in that the Host is about to begin a phase of the IO cycle for a particular device.
  // This is called at the beginning of an IO operation. This device doesn't do anything, so just
  // check the arguments and return.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  return noErr
}

func EQV_DoIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inStreamObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>,
  ioMainBuffer: UnsafeMutableRawPointer?,
  ioSecondaryBuffer: UnsafeMutableRawPointer?
) -> OSStatus {
  // This is called to actuall perform a given operation.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  guard let sample = ioMainBuffer?.assumingMemoryBound(to: Float32.self) else {
    return noErr
  }

  let client = EQVClients.get(clientId: inClientID)

  let status = EQVDevice.doIO(
    client: client,
    operationID: inOperationID,
    sample: sample,
    cycleInfo: inIOCycleInfo.pointee,
    frameSize: inIOBufferFrameSize
  )

  return status
}

func EQV_EndIOOperation (
  inDriver: AudioServerPlugInDriverRef,
  inDeviceObjectID: AudioObjectID,
  inClientID: UInt32,
  inOperationID: UInt32,
  inIOBufferFrameSize: UInt32,
  inIOCycleInfo: UnsafePointer<AudioServerPlugInIOCycleInfo>
) -> OSStatus {
  // This is called at the end of an IO operation. This device doesn't do anything, so just check
  // the arguments and return.
  guard EQVDriver.validateDriver(inDriver) else { return kAudioHardwareBadObjectError }

  return noErr
}
