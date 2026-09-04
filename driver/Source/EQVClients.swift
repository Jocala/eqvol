//
//  EQVClients.swift
//  eqVol
//


//

import Foundation
import CoreAudio.AudioServerPlugIn
import Shared

class EQVClients {
  private static let mutex = Mutex()
  static var clients: [UInt32: EQVClient] = [:]

  static func add (_ client: EQVClient) {
    mutex.lock()
    clients[client.clientId] = client
    mutex.unlock()
  }

  static func remove (_ client: EQVClient) {
    mutex.lock()
    clients.removeValue(forKey: client.clientId)
    mutex.unlock()
  }

  static func get (clientId: UInt32) -> EQVClient? {
    mutex.lock()
    let client = clients[clientId]
    mutex.unlock()
    return client
  }

  static func get (processId: pid_t) -> EQVClient? {
    mutex.lock()
    let client = clients.values.first { $0.processId == processId }
    mutex.unlock()
    return client
  }

  static func get (bundleId: String) -> [EQVClient] {
    mutex.lock()
    let matchingClients = clients.values.filter { client in
      return client.bundleId == bundleId
    }
    mutex.unlock()
    return matchingClients
  }

  static func get (client: EQVClient) -> EQVClient? {
    if let byClient = get(clientId: client.clientId) {
      return byClient
    }

    if let byProcessId = get(processId: client.processId) {
      return byProcessId
    }

    if let bundleId = client.bundleId {
      let bundles = get(bundleId: bundleId)
      return bundles[0]
    }

    return nil
  }

  static var isAppClientPresent: Bool {
    return Array(clients.values).contains { $0.bundleId == APP_BUNDLE_ID }
  }
}

