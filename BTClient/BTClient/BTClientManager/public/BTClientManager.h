/*
 * Copyright (c) 2013, Alexander Mandravin(alexander.mandravin@gmail.com)
 * All rights reserved.
 * 
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met: 
 * 
 * 1. Redistributions of source code must retain the above copyright notice, this
 *    list of conditions and the following disclaimer. 
 * 2. Redistributions in binary form must reproduce the above copyright notice,
 *    this list of conditions and the following disclaimer in the documentation
 *    and/or other materials provided with the distribution. 
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 * 
 * The views and conclusions contained in the software and documentation are those
 * of the authors and should not be interpreted as representing official policies, 
 * either expressed or implied, of the FreeBSD Project.
 */

#import <Foundation/Foundation.h>


@protocol BTServerDelegate <NSObject>

@optional

// Invoked on sending data to server success or fail. See sendData.
// -btServer: sender
// -data: data to be sent to server
// -success: send result. YES if success and NO if fail.
- (void) btServer:(id)btServer didSendData:(NSData*)data success:(BOOL)success;

@end


// BT Server. Represents remote device that client is connected to.
@interface BTServer : NSObject

// Setup server delegate. See BTServerDelegate.
// -delegate: delegate to be notified with send data to server results.
- (void) setDelegate:(id<BTServerDelegate>)delegate;

// Returns latest known RSSI
- (NSInteger) getRSSI;

// Returns server UUID
- (NSString*) getUUID;

// Returns server device name
- (NSString*) getName;

// Send data to server. Delegate will be notified with send result in sync way. See BTServerDelegate.
// -data: data to send. There are no any limitation on data lenght.
- (void) sendData:(NSData*)data;

@end


// BT Client Manager Delegate protocol
@protocol BTClientManagerDelegate <NSObject>

@optional

// Invoked whenever BT Client state is changed.
// -btManager: sender
// -start: YES if BT client manager is active and NO otherwise
- (void) btClientManager:(id)btManager didStart:(BOOL)start;

// Invoked on connecting to server
// -btManager: sender
// -server: sever which client is connected to
- (void) btClientManager:(id)btManager didConnectToServer:(BTServer*)server;

// Invoked on disconnecting from server
// -btManager: sender
// -server: sever whicn client is disconnected from
- (void) btClientManager:(id)btManager didDisconnectFromServer:(BTServer*)server;

// Invoked whenever RSSI value is updated
// -btManager: sender
// -rssi: new RSSI value for connection to server
- (void) btClientManager:(id)btManager didUpdateRSSI:(NSInteger)rssi;

@end


// BT Client Manager
@interface BTClientManager : NSObject

// Redefine internal BTClientManager log output. By default logging is turned off.
// -block: block to be used for custom logging
+ (void) setCustomLoggerBlock:(void (^)(NSString*))block;

// Designated initializer
// -delegate: delegate. See BTClientManagerDelegate.
// -serviceUUID: target service UUID for connecting
// -characteristicUUID: target characteristic UUID for connecting
- (id) initWithDelegate:(id<BTClientManagerDelegate>)delegate
            serviceUUID:(NSString*)serviceUUID
     characteristicUUID:(NSString*)characteristicUUID;

// Set RSSI refresh interval
// -interval: refresh interval. By default is 5 sec. 0 sec is valid value, in this case get RSSI and send it to server will be turned off.
- (void) setRSSIRefreshInterval:(NSTimeInterval)interval;

// Returns currently connected server
- (BTServer*) getServer;

@end
