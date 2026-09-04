//
// EQVDriverBridge.m
//  eqVol
//


//

#import "EQVDriverBridge.h"
#import "EQVDriver-Swift.h"

void *EQV_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
  return [EQVDriver createWithAllocator:allocator requestedTypeUUID:requestedTypeUUID];
}
