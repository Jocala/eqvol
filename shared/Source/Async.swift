//
//  File.swift
//  
//

//

import Foundation

public class Async {
  static public func delay (_ milliseconds: UInt, completion: @escaping () -> ()) {
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(milliseconds) / 1000) { completion() }
  }
}
