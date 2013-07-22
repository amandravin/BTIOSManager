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


#import "BTClientManager.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import "ThreadUtil.h"


typedef void (^customLogBlock)(NSString* message);

static customLogBlock __g_customLogBlock = nil;
static CFRunLoopRef __g_customLogBlockRunLoop = nil;


class BTClientGarbageCollector
{
public:
    ~BTClientGarbageCollector()
    {
        if (__g_customLogBlock)
        {
            Block_release(__g_customLogBlock);
            __g_customLogBlock = nil;
        }
    }
};

static BTClientGarbageCollector __g_garbageCollector;


#define DLog(__FORMAT__, ...)                                                                         \
do                                                                                                    \
{                                                                                                     \
    if (__g_customLogBlock)                                                                           \
    {                                                                                                 \
        NSString* btc_dlog_string = [[NSString stringWithFormat:(__FORMAT__), ##__VA_ARGS__] retain]; \
        [CustomThread asyncRunBlock: ^                                                                \
        {                                                                                             \
            __g_customLogBlock(btc_dlog_string);                                                      \
            [btc_dlog_string release];                                                                \
        }                                                                                             \
        inRunLoop:__g_customLogBlockRunLoop];                                                         \
    }                                                                                                 \
}                                                                                                     \
while(0);                                                                                             \


#define MAX_BT_PACKET_SIZE                 20
#define DEFAULT_REFRESH_RSSI_INTERVAL       5.0
#define RESTART_SCAN_TIMEOUT                3.0
#define IMPOSSIBLY_MIN_RSSI_VALUE       -1000.0
#define TRY_RESEND_DATA_TIMEOUT             1.0
#define RESEND_DATA_RETRY_COUNT             3
#define NO_SERVER_RECONNECT_TIMEOUT        10.0


@interface BTClientManager(forward)

+ (NSString*) convertCFUUIDRefToNSString:(CFUUIDRef)uuidRef;

@end


@interface BTData : NSObject
{
    NSData*      m_data;
    BOOL         m_endWithEOM;
    NSInteger    m_sendDataIndex;
    NSInteger    m_newSendDataIndex;
    BOOL         m_eomIsSent;
}

@property (nonatomic, retain) NSData* m_data;
@property (nonatomic, assign) BOOL m_endWithEOM;
@property (nonatomic, assign) NSInteger m_sendDataIndex;
@property (nonatomic, assign) NSInteger m_newSendDataIndex;
@property (nonatomic, assign) BOOL m_eomIsSent;

- (id) initWithData:(NSData*)data endWithEOM:(BOOL)eom;

- (void) markAsSentSuccess;
- (void) markAsSentFail;

@end


@implementation BTData

@synthesize m_data;
@synthesize m_endWithEOM;
@synthesize m_sendDataIndex;
@synthesize m_newSendDataIndex;
@synthesize m_eomIsSent;

- (id) initWithData:(NSData*)data endWithEOM:(BOOL)eom
{
    if (self = [super init])
    {
        self.m_data = data;
        m_endWithEOM = eom;
    }

    return self;
}

- (void) dealloc
{
    [m_data release];
    [super dealloc];
}

- (void) markAsSentSuccess
{
    m_sendDataIndex = m_newSendDataIndex;
}

- (void) markAsSentFail
{
    m_newSendDataIndex = 0;
    m_eomIsSent = NO;
}

@end


@interface BTServer()
{
    id<BTServerDelegate>  m_delegate;
    CFRunLoopRef          m_btServerRunLoop;
    CFRunLoopRef          m_clientRunLoop;
    CBPeripheral*         m_peripheral;
    CBCharacteristic*     m_characteristic;
    BOOL                  m_connected;
    NSMutableArray*       m_sendDataQueue;
    BOOL                  m_sendingInProgress;
    NSLock*               m_lock;
    NSInteger             m_rssi;
    NSTimer*              m_resendTimer;
    NSInteger             m_tryResendCount;
}

@property (nonatomic, assign) id<BTServerDelegate> m_delegate;
@property (nonatomic, retain) CBPeripheral* m_peripheral;
@property (nonatomic, retain) CBCharacteristic* m_characteristic;
@property (nonatomic, assign) BOOL m_connected;
@property (nonatomic, retain) NSMutableArray* m_sendDataQueue;
@property (nonatomic, assign) BOOL m_sendingInProgress;
@property (nonatomic, retain) NSTimer* m_resendTimer;

- (id) initWithServerRunLoop:(CFRunLoopRef)serverRunLoop clientRunLoop:(CFRunLoopRef)clientRunLoop andPeripheral:(CBPeripheral*)peripheral;

- (void) send:(BTData*)btData;
- (void) doSendIteration;
- (void) setRSSI:(NSInteger)rssi;

- (BOOL) tryResendDataAfterTimeout;
- (void) startResendDataTimer;
- (void) stopResendDataTimer;
- (void) resendDataTimerFaired:(id)sender;
- (void) dataSendSuccess;
- (void) dataSendFail;

@end


@implementation BTServer

@synthesize m_delegate;
@synthesize m_peripheral;
@synthesize m_characteristic;
@synthesize m_connected;
@synthesize m_sendDataQueue;
@synthesize m_sendingInProgress;
@synthesize m_resendTimer;

- (id) initWithServerRunLoop:(CFRunLoopRef)serverRunLoop clientRunLoop:(CFRunLoopRef)clientRunLoop andPeripheral:(CBPeripheral*)peripheral
{
    if (self = [super init])
    {
        m_btServerRunLoop = serverRunLoop;
        m_clientRunLoop = clientRunLoop;
        self.m_peripheral = peripheral;
        m_rssi = IMPOSSIBLY_MIN_RSSI_VALUE;
        m_sendDataQueue = [[NSMutableArray alloc] init];
        m_lock = [[NSLock alloc] init];
    }

    return self;
}

- (void) dealloc
{
    m_delegate = nil;
    [self stopResendDataTimer];
    [m_peripheral release];
    [m_characteristic release];
    [m_sendDataQueue release];
    [m_lock release];
    [super dealloc];
}

- (void) send:(BTData*)btData
{
    [m_sendDataQueue addObject:btData];

    if (!m_sendingInProgress)
    {
        DLog(@"BTClientManager: SENDING STARTED");
        m_sendingInProgress = YES;
        [self doSendIteration];
    }
}

- (void) doSendIteration
{
    if ([m_sendDataQueue count] == 0 || !m_sendingInProgress || !m_connected || !m_peripheral)
    {
        DLog(@"BTClientManager: SENDING STOPPED");
        m_sendingInProgress = NO;
        return;
    }

    BTData* btData = [m_sendDataQueue objectAtIndex:0];
    int sendDataSize = [btData.m_data length] - btData.m_sendDataIndex;
    if (sendDataSize > MAX_BT_PACKET_SIZE)
    {
        sendDataSize = MAX_BT_PACKET_SIZE;
    }
    else if (sendDataSize <= 0)
    {
        if (btData.m_endWithEOM && !btData.m_eomIsSent)
        {
            btData.m_eomIsSent = YES;

            NSData* eomData = [@"EOM" dataUsingEncoding:NSUTF8StringEncoding];

            DLog(@"BTClientManager: >>> peripheral writeValue EOM");
            [m_peripheral writeValue:eomData forCharacteristic:m_characteristic type:CBCharacteristicWriteWithResponse];
        }
        else
        {
            if (btData.m_endWithEOM)
            {
                NSData* data = [btData.m_data retain];
                [CustomThread asyncRunBlock: ^
                {
                    if ([m_delegate respondsToSelector:@selector(btServer:didSendData:success:)])
                    {
                        DLog(@"BTClientManager: >>> delegate didSendData");
                        [m_delegate btServer:self didSendData:data success:YES];
                    }

                    [data release];
                }
                inRunLoop:m_clientRunLoop];
            }

            [m_sendDataQueue removeObjectAtIndex:0];
            [self doSendIteration];
        }

        return;
    }

    NSData* dataToSend = [NSData dataWithBytes:(uint8_t*)[btData.m_data bytes] + btData.m_sendDataIndex length:sendDataSize];
    btData.m_newSendDataIndex = btData.m_sendDataIndex + sendDataSize;

    DLog(@"BTClientManager: >>> peripheral writeValue data[%@]", dataToSend);
    [m_peripheral writeValue:dataToSend forCharacteristic:m_characteristic type:CBCharacteristicWriteWithResponse];
}

- (BOOL) isConnected
{
    return m_connected;
}

- (void) setRSSI:(NSInteger)rssi
{
    CustomLock lock(m_lock);
    m_rssi = rssi;
}

- (void) setDelegate:(id<BTServerDelegate>)delegate
{
    m_delegate = delegate;
}

- (NSInteger) getRSSI
{
    CustomLock lock(m_lock);
    return m_rssi;
}

- (NSString*) getUUID
{
    CustomLock lock(m_lock);
    NSString* uuid = [BTClientManager convertCFUUIDRefToNSString:m_peripheral.UUID];
    return uuid;
}

- (NSString*) getName
{
    NSString* name = nil;

    CustomLock lock(m_lock);
    if ([m_peripheral.name length] > 0)
    {
        name = [NSString stringWithString:m_peripheral.name];
    }

    return name;
}

- (void) sendData:(NSData*)data
{
    DLog(@"BTClientManager:sendData");

    if (!data || [data length] == 0)
    {
        DLog(@"BTClientManager:sendData: Error. Data is empty!");
        return;
    }

    NSData* sendData = [[NSData dataWithData:data] retain];
    [CustomThread asyncRunBlock: ^
    {
        if (!m_peripheral || !m_connected)
        {
            DLog(@"BTClientManager:sendData: Error. Server is not connected");
            if ([m_delegate respondsToSelector:@selector(btServer:didSendData:success:)])
            {
                DLog(@"BTClientManager: >>> delegate didSendData");
                [m_delegate btServer:self didSendData:sendData success:NO];
            }
        }
        else
        {
            [self send:[[[BTData alloc] initWithData:sendData endWithEOM:YES] autorelease]];
        }

        [sendData release];
    }
    inRunLoop:m_btServerRunLoop];
}

- (BOOL) tryResendDataAfterTimeout
{
    m_tryResendCount++;
    DLog(@"BTClientManager:tryResendDataAfterTimeout = %d", m_tryResendCount);
    if (m_tryResendCount > RESEND_DATA_RETRY_COUNT)
    {
        return NO;
    }
    else
    {
        [self startResendDataTimer];
    }

    return YES;
}

- (void) startResendDataTimer
{
    [self stopResendDataTimer];
    DLog(@"BTClientManager:startResendDataTimer");
    self.m_resendTimer = [NSTimer scheduledTimerWithTimeInterval:TRY_RESEND_DATA_TIMEOUT target:self selector:@selector(resendDataTimerFaired:) userInfo:nil repeats:NO];
}

- (void) stopResendDataTimer
{
    if (m_resendTimer)
    {
        DLog(@"BTClientManager:stopResendDataTimer");
        [m_resendTimer invalidate];
        self.m_resendTimer = nil;
    }
}

- (void) resendDataTimerFaired:(id)sender
{
    DLog(@"BTClientManager:resendDataTimerFaired");
    [self stopResendDataTimer];
    [self doSendIteration];
}

- (void) dataSendSuccess
{
    m_tryResendCount = 0;
    if ([m_sendDataQueue count] > 0)
    {
        BTData* data = [m_sendDataQueue objectAtIndex:0];
        [data markAsSentSuccess];
    }
}

- (void) dataSendFail
{
    if ([m_sendDataQueue count] > 0)
    {
        BTData* data = [m_sendDataQueue objectAtIndex:0];
        [data markAsSentFail];
    }
}

@end


@interface BTClientManager() <CBCentralManagerDelegate, CBPeripheralDelegate>
{
    CustomThread*                  m_btManagerThread;
    CBCentralManager*              m_centralManager;
    CFRunLoopRef                   m_clientRunLoop;
    BTServer*                      m_server;
    NSString*                      m_serviceUUID;
    NSString*                      m_characteristicUUID;
    id<BTClientManagerDelegate>    m_delegate;
    NSTimer*                       m_sendRSSITimer;
    NSTimeInterval                 m_rssiRefreshInterval;
    NSTimer*                       m_restartScanTimer;
    BOOL                           m_scanStarted;
    NSTimer*                       m_noServerTimer;
}

@property (nonatomic, retain) BTServer* m_server;
@property (nonatomic, retain) NSTimer* m_sendRSSITimer;
@property (nonatomic, retain) NSTimer* m_restartScanTimer;
@property (nonatomic, retain) NSTimer* m_noServerTimer;

- (void) startScan;
- (void) stopScan;
- (void) restartScan;
- (void) restartScanAfterTimeout;
- (void) startRestartScanTimer;
- (void) stopRestartScanTimer;
- (void) restartScanTimerFaired:(id)sender;
- (void) disconnectFromServer;
- (void) sendRSSI;
- (void) startSendRSSITimer;
- (void) stopSendRSSITimer;
- (void) sendRSSITimerFaired:(id)sender;
- (void) dataSendSuccess;
- (void) dataSendFail;
- (void) startNoServerTimer;
- (void) stopNoServerTimer;
- (void) noServerTimerFaired:(id)sender;

@end


@implementation BTClientManager

@synthesize m_server;
@synthesize m_sendRSSITimer;
@synthesize m_restartScanTimer;
@synthesize m_noServerTimer;

- (id) initWithDelegate:(id<BTClientManagerDelegate>)delegate
            serviceUUID:(NSString*)serviceUUID
     characteristicUUID:(NSString*)characteristicUUID;
{
    if (self = [super init])
    {
        m_delegate = delegate;
        m_serviceUUID = [serviceUUID retain];
        m_characteristicUUID = [characteristicUUID retain];
        m_rssiRefreshInterval = DEFAULT_REFRESH_RSSI_INTERVAL;
        m_clientRunLoop = CFRunLoopGetCurrent();

        m_btManagerThread = [[CustomThread alloc] init];

        [CustomThread asyncRunBlock: ^
        {
            m_centralManager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
        }
        inRunLoop:[m_btManagerThread getRunLoop]];
    }

    return self;
}

- (void) dealloc
{
    m_delegate = nil;

    [CustomThread syncRunBlock: ^
    {
        [self stopSendRSSITimer];
        [self stopRestartScanTimer];
        [self stopNoServerTimer];
        [self stopScan];
        [m_centralManager release];
    }
    inRunLoop:[m_btManagerThread getRunLoop]];

    [m_serviceUUID release];
    [m_characteristicUUID release];

    if (CFRunLoopGetCurrent() != [m_btManagerThread getRunLoop])
    {
        [m_btManagerThread join];
        [m_btManagerThread release];
        m_btManagerThread = nil;
    }
    else
    {
        NSLog(@"Error: BTClientManager: join to BTClientManager thread from self! Use another thread for BTClientManager release.");
    }

    [super dealloc];
}

- (void) centralManagerDidUpdateState:(CBCentralManager*)central
{
    DLog(@"BTClientManager:centralManagerDidUpdateState: %d", [m_centralManager state]);

    switch ([m_centralManager state])
    {
        case CBCentralManagerStatePoweredOn:
        {
            [self restartScan];
            break;
        }

        default:
        {
            [self stopScan];
            break;
        }
    }
}

- (void) centralManager:(CBCentralManager*)central didRetrievePeripherals:(NSArray*)peripherals
{
    DLog(@"BTClientManager:centralManager:didRetrievePeripherals");
}

- (void) centralManager:(CBCentralManager*)central didRetrieveConnectedPeripherals:(NSArray*)peripherals
{
    DLog(@"BTClientManager:centralManager:didRetrieveConnectedPeripherals");
}

- (void) centralManager:(CBCentralManager*)central didDiscoverPeripheral:(CBPeripheral*)peripheral advertisementData:(NSDictionary*)advertisementData RSSI:(NSNumber*)RSSI
{
    DLog(@"BTClientManager:centralManager:didDiscoverPeripheral:advertisementData:RSSI[%d]", RSSI.integerValue);

    if (m_server)
    {
        DLog(@"BTClientManager: Error. Server is already available!");
        [self restartScanAfterTimeout];
        return;
    }

    m_server = [[BTServer alloc] initWithServerRunLoop:[m_btManagerThread getRunLoop] clientRunLoop:m_clientRunLoop andPeripheral:peripheral];

    NSArray* objects = [NSArray arrayWithObjects:[NSNumber numberWithBool:YES], [NSNumber numberWithBool:YES], [NSNumber numberWithBool:YES], nil];
    NSArray* keys = [NSArray arrayWithObjects:CBConnectPeripheralOptionNotifyOnDisconnectionKey, CBConnectPeripheralOptionNotifyOnConnectionKey, CBConnectPeripheralOptionNotifyOnNotificationKey, nil];

    DLog(@"BTClientManager: >>> centralManager connectPeripheral");
    [m_centralManager connectPeripheral:m_server.m_peripheral options:[NSDictionary dictionaryWithObjects:objects forKeys:keys]];
}

- (void) centralManager:(CBCentralManager*)central didConnectPeripheral:(CBPeripheral*)peripheral
{
    DLog(@"BTClientManager:centralManager:didConnectPeripheral:");

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
        [self restartScanAfterTimeout];
        return;
    }

    NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
    NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
    if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
    {
        DLog(@"BTClientManager: Error. Connected to unknown peripheral!");
        [self restartScanAfterTimeout];
        return;
    }

    if (m_server.m_connected)
    {
        DLog(@"BTClientManager: Error. Server is already connected!");
        return;
    }

    [m_server.m_peripheral setDelegate:self];

    DLog(@"BTClientManager: >>> client discoverServices");
    [m_server.m_peripheral discoverServices:[NSArray arrayWithObject:[CBUUID UUIDWithString:m_serviceUUID]]];
}

- (void) centralManager:(CBCentralManager*)central didFailToConnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error
{
    DLog(@"BTClientManager:centralManager:didFailToConnectPeripheral:error [%@]", [error localizedDescription]);

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
    }
    else
    {
        NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
        NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
        if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
        {
            DLog(@"BTClientManager: Error. Unknown peripheral!");
        }
    }

    [self restartScanAfterTimeout];
}

- (void) centralManager:(CBCentralManager*)central didDisconnectPeripheral:(CBPeripheral*)peripheral error:(NSError*)error
{
    DLog(@"BTClientManager:centralManager:didDisconnectPeripheral:error [%@]", [error localizedDescription]);

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
    }
    else
    {
        NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
        NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
        if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
        {
            DLog(@"BTClientManager: Error. Unknown peripheral!");
        }
    }

    [self restartScanAfterTimeout];
}

- (void) peripheralDidUpdateName:(CBPeripheral*)peripheral
{
    DLog(@"BTClientManager:peripheralDidUpdateName");
}

- (void) peripheralDidInvalidateServices:(CBPeripheral*)peripheral
{
    DLog(@"BTClientManager:peripheralDidInvalidateServices");
    [self restartScanAfterTimeout];
}

- (void) peripheralDidUpdateRSSI:(CBPeripheral*)peripheral error:(NSError*)error
{
    DLog(@"BTClientManager:peripheralDidUpdateRSSI:[%d] error [%@]", peripheral.RSSI.integerValue, [error localizedDescription]);

    if (m_server && m_server.m_peripheral && m_server.m_connected)
    {
        NSInteger newRSSI = peripheral.RSSI.integerValue;
        [m_server setRSSI:newRSSI];

        BTServer* server = [m_server retain];
        [CustomThread asyncRunBlock: ^
        {
            if ([m_delegate respondsToSelector:@selector(btClientManager:didUpdateRSSI:)])
            {
                DLog(@"BTClientManager: >>> delegate didUpdateRSSI %d", newRSSI);
                [m_delegate btClientManager:self didUpdateRSSI:newRSSI];
            }

            [server release];
        }
        inRunLoop:m_clientRunLoop];

        [self sendRSSI];
    }
}

- (void) peripheral:(CBPeripheral*)peripheral didDiscoverServices:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didDiscoverServices");

    if (error) 
    {
        DLog(@"BTClientManager:peripheral:didDiscoverServices:error [%@]", [error localizedDescription]);
        [self restartScanAfterTimeout];
        return;
    }

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
        [self restartScanAfterTimeout];
        return;
    }

    NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
    NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
    if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
    {
        DLog(@"BTClientManager: Error. Unknown peripheral!");
        [self restartScanAfterTimeout];
        return;
    }

    if (m_server.m_connected)
    {
        DLog(@"BTClientManager: Error. Server is already connected!");
        return;
    }

    for (CBService* service in peripheral.services)
    {
        DLog(@"BTClientManager: >>> server discoverCharacteristics");
        [m_server.m_peripheral discoverCharacteristics:[NSArray arrayWithObject:[CBUUID UUIDWithString:m_characteristicUUID]] forService:service];
    }
}

- (void) peripheral:(CBPeripheral*)peripheral didDiscoverIncludedServicesForService:(CBService*)service error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didDiscoverIncludedServicesForService:error [%@]", [error localizedDescription]);
}

- (void) peripheral:(CBPeripheral*)peripheral didDiscoverCharacteristicsForService:(CBService*)service error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didDiscoverCharacteristicsForService");

    if (error) 
    {
        DLog(@"BTClientManager:peripheral:didDiscoverCharacteristicsForService:error [%@]", [error localizedDescription]);
        [self restartScanAfterTimeout];
        return;
    }

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
        [self restartScanAfterTimeout];
        return;
    }

    NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
    NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
    if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
    {
        DLog(@"BTClientManager: Error. Unknown peripheral!");
        [self restartScanAfterTimeout];
        return;
    }

    if (m_server.m_connected)
    {
        DLog(@"BTClientManager: Error. Server is already connected!");
        return;
    }

    BOOL success = NO;
    for (CBCharacteristic* characteristic in service.characteristics)
    {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:m_characteristicUUID]])
        {
            success = YES;
            DLog(@"BTClientManager: >>> server setNotifyValue");
            [m_server.m_peripheral setNotifyValue:YES forCharacteristic:characteristic];
        }
        else
        {
            DLog(@"BTClientManager: Error. Transfer characteristic is not available!");
        }
    }

    if (!success)
    {
        [self restartScanAfterTimeout];
    }
}

- (void) peripheral:(CBPeripheral*)peripheral didUpdateValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didUpdateValueForCharacteristic:error [%@]", [error localizedDescription]);
}

 - (void) peripheral:(CBPeripheral*)peripheral didWriteValueForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didWriteValueForCharacteristic:error [%@]", [error localizedDescription]);

    if (m_server)
    {
        if (error)
        {
            DLog(@"BTClientManager: Error. Write is failed!");
            [self dataSendFail];
        }
        else
        {
            [self dataSendSuccess];
        }
    }
}

- (void) peripheral:(CBPeripheral*)peripheral didUpdateNotificationStateForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didUpdateNotificationStateForCharacteristic:");

    if (error) 
    {
        DLog(@"BTClientManager:peripheral:didUpdateNotificationStateForCharacteristic:error %@", [error localizedDescription]);
        [self restartScanAfterTimeout];
        return;
    }

    if (!m_server)
    {
        DLog(@"BTClientManager: Error. Server is not available!");
        [self restartScanAfterTimeout];
        return;
    }

    NSString* uuid1 = [BTClientManager convertCFUUIDRefToNSString:peripheral.UUID];
    NSString* uuid2 = [BTClientManager convertCFUUIDRefToNSString:m_server.m_peripheral.UUID];
    if (uuid1 == nil || uuid2 == nil || [uuid1 compare:uuid2] != NSOrderedSame)
    {
        DLog(@"BTClientManager: Error. Unknown peripheral!");
        [self restartScanAfterTimeout];
        return;
    }

    if (m_server.m_connected)
    {
        DLog(@"BTClientManager: Error. Server is already connected!");
        return;
    }

    if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:m_characteristicUUID]])
    {
        if ([characteristic isNotifying])
        {
            DLog(@"BTClientManager: Connected to server");
            m_server.m_connected = YES;
            m_server.m_characteristic = characteristic;

            [self startSendRSSITimer];
            [self stopNoServerTimer];

            DLog(@"BTClientManager: >>> peripheral readRSSI");
            [m_server.m_peripheral readRSSI];

            BTServer* server = [m_server retain];
            [CustomThread asyncRunBlock: ^
            {
                if ([m_delegate respondsToSelector:@selector(btClientManager:didConnectToServer:)])
                {
                    DLog(@"BTClientManager: >>> delegate didConnectToServer");
                    [m_delegate btClientManager:self didConnectToServer:server];
                }

                [server release];
            }
            inRunLoop:m_clientRunLoop];
        }
        else
        {
            DLog(@"BTClientManager: Error. Characteristic is not set to notifying!");
            [self restartScanAfterTimeout];
        }
    }
    else
    {
        DLog(@"BTClientManager: Error. Characteristic is not available!");
        [self restartScanAfterTimeout];
    }
}

- (void) peripheral:(CBPeripheral*)peripheral didDiscoverDescriptorsForCharacteristic:(CBCharacteristic*)characteristic error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didDiscoverDescriptorsForCharacteristic:error [%@]", [error localizedDescription]);
}

- (void) peripheral:(CBPeripheral*)peripheral didUpdateValueForDescriptor:(CBDescriptor*)descriptor error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didUpdateValueForDescriptor:error [%@]", [error localizedDescription]);
}

- (void) peripheral:(CBPeripheral*)peripheral didWriteValueForDescriptor:(CBDescriptor*)descriptor error:(NSError*)error
{
    DLog(@"BTClientManager:peripheral:didWriteValueForDescriptor:error [%@]", [error localizedDescription]);
}

- (void) startScan
{
    if (!m_scanStarted)
    {
        DLog(@"BTClientManager:startScan");

        NSDictionary* options = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:NO], CBCentralManagerScanOptionAllowDuplicatesKey, nil];

        DLog(@"BTClientManager: >>> centralManager scanForPeripheralsWithServices");
        [m_centralManager scanForPeripheralsWithServices:[NSArray arrayWithObject:[CBUUID UUIDWithString:m_serviceUUID]] options:options];

        m_scanStarted = YES;
        [self startNoServerTimer];

        [CustomThread asyncRunBlock: ^
        {
            if ([m_delegate respondsToSelector:@selector(btClientManager:didStart:)])
            {
                DLog(@"BTClientManager: >>> delegate didStart YES");
                [m_delegate btClientManager:self didStart:YES];
            }
        }
        inRunLoop:m_clientRunLoop];
    }
}

- (void) stopScan
{
    [self disconnectFromServer];

    if (m_scanStarted)
    {
        DLog(@"BTClientManager:stopScan");

        m_scanStarted = NO;
        [self stopNoServerTimer];

        DLog(@"BTClientManager: >>> centralManager stopScan");
        [m_centralManager stopScan];

        [CustomThread asyncRunBlock: ^
        {
            if ([m_delegate respondsToSelector:@selector(btClientManager:didStart:)])
            {
                DLog(@"BTClientManager: >>> delegate didStart NO");
                [m_delegate btClientManager:self didStart:NO];
            }
        }
        inRunLoop:m_clientRunLoop];
    }
}

- (void) restartScan
{
    DLog(@"BTClientManager:restartScan");
    [self stopScan];
    [self startScan];
}

- (void) restartScanAfterTimeout
{
    DLog(@"BTClientManager:restartScanAfterTimeout");
    [self startRestartScanTimer];
    [self stopScan];
}

- (void) startRestartScanTimer
{
    [self stopRestartScanTimer];

    DLog(@"BTClientManager:startRestartScanTimer");
    self.m_restartScanTimer = [NSTimer scheduledTimerWithTimeInterval:RESTART_SCAN_TIMEOUT target:self selector:@selector(restartScanTimerFaired:) userInfo:nil repeats:NO];
}

- (void) stopRestartScanTimer
{
    if (m_restartScanTimer)
    {
        DLog(@"BTClientManager:stopRestartScanTimer");
        [m_restartScanTimer invalidate];
        self.m_restartScanTimer = nil;
    }
}

- (void) restartScanTimerFaired:(id)sender
{
    DLog(@"BTClientManager:restartScanTimerFaired");
    [self stopRestartScanTimer];
    [self startScan];
}

- (void) disconnectFromServer
{
    [self stopSendRSSITimer];

    if (m_server)
    {
        DLog(@"BTClientManager:disconnectFromServer");
        if (m_server.m_connected)
        {
            m_server.m_connected = NO;
            [m_server stopResendDataTimer];

            NSMutableArray* pendingDataToSend = [[NSMutableArray array] retain];
            for (BTData* data in m_server.m_sendDataQueue)
            {
                if (data.m_endWithEOM)
                {
                    [pendingDataToSend addObject:data.m_data];
                }
            }

            BTServer* server = [m_server retain];
            [CustomThread asyncRunBlock: ^
            {
                if ([server.m_delegate respondsToSelector:@selector(btServer:didSendData:success:)])
                {
                    for (NSData* data in pendingDataToSend)
                    {
                        [server.m_delegate btServer:server didSendData:data success:NO];
                    }
                }

                if ([m_delegate respondsToSelector:@selector(btClientManager:didDisconnectFromServer:)])
                {
                    DLog(@"BTClientManager: >>> delegate didDisconnectFromServer");
                    [m_delegate btClientManager:self didDisconnectFromServer:server];
                }

                [pendingDataToSend release];
                [server release];
            }
            inRunLoop:m_clientRunLoop];
        }

        if (m_server.m_peripheral)
        {
            DLog(@"BTClientManager: >>> centralManager cancelPeripheralConnection");
            [m_centralManager cancelPeripheralConnection:m_server.m_peripheral];
        }

        m_server.m_peripheral.delegate = nil;
        self.m_server = nil;
    }
}

+ (NSString*) convertCFUUIDRefToNSString:(CFUUIDRef)uuidRef
{
    if (!uuidRef)
    {
        return nil;
    }

    CFStringRef clientUUIDRef = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
    if (!clientUUIDRef)
    {
        return nil;
    }

    NSString* clientUUID = [NSString stringWithString:(NSString*)clientUUIDRef];
    CFRelease(clientUUIDRef);

    return clientUUID;
}

- (void) sendRSSI
{
    if (!m_server || !m_server.m_peripheral || !m_server.m_connected || m_rssiRefreshInterval <= 0)
    {
        DLog(@"BTClientManager:sendRSSI: Error. Wrong param!");
        return;
    }

    NSInteger rssi = [m_server getRSSI];
    NSString* message = [NSString stringWithFormat:@"RSSI %d", rssi];
    NSData* data = [message dataUsingEncoding:NSUTF8StringEncoding];

    DLog(@"BTClientManager:sendRSSI = %d", rssi);
    [m_server send:[[[BTData alloc] initWithData:data endWithEOM:NO] autorelease]];
}

- (void) startSendRSSITimer
{
    [self stopSendRSSITimer];

    if (!m_server || !m_server.m_peripheral || !m_server.m_connected || m_rssiRefreshInterval <= 0)
    {
        DLog(@"BTClientManager:startSendRSSITimer: Error. Wrong param!");
        return;
    }

    DLog(@"BTClientManager:startSendRSSITimer");
    self.m_sendRSSITimer = [NSTimer scheduledTimerWithTimeInterval:m_rssiRefreshInterval target:self selector:@selector(sendRSSITimerFaired:) userInfo:nil repeats:YES];
}

- (void) stopSendRSSITimer
{
    if (m_sendRSSITimer)
    {
        DLog(@"BTClientManager:stopSendRSSITimer");
        [m_sendRSSITimer invalidate];
        self.m_sendRSSITimer = nil;
    }
}

- (void) sendRSSITimerFaired:(id)sender
{
    DLog(@"BTClientManager:sendRSSITimerFaired");
    if (!m_server || !m_server.m_peripheral || !m_server.m_connected || m_rssiRefreshInterval <= 0)
    {
        DLog(@"BTClientManager:sendRSSITimerFaired: Error. Wrong param!");
        [self stopSendRSSITimer];
        return;
    }

    DLog(@"BTClientManager: >>> peripheral readRSSI");
    [m_server.m_peripheral readRSSI];
}

- (void) dataSendSuccess
{
    DLog(@"BTClientManager:dataSendSuccess");
    if (m_server)
    {
        [m_server dataSendSuccess];
        [m_server doSendIteration];
    }
}

- (void) dataSendFail
{
    DLog(@"BTClientManager:dataSendFail");
    if (m_server)
    {
        [m_server dataSendFail];

        if (![m_server tryResendDataAfterTimeout])
        {
            [self restartScanAfterTimeout];
        }
    }
}

- (void) startNoServerTimer
{
    [self stopNoServerTimer];

    if (m_server &&  m_server.m_peripheral && m_server.m_connected)
    {
        return;
    }

    DLog(@"BTClientManager:startNoServerTimer");
    self.m_noServerTimer = [NSTimer scheduledTimerWithTimeInterval:NO_SERVER_RECONNECT_TIMEOUT target:self selector:@selector(noServerTimerFaired:) userInfo:nil repeats:NO];
}

- (void) stopNoServerTimer
{
    if (m_noServerTimer)
    {
        DLog(@"BTClientManager:stopNoServerTimer");
        [m_noServerTimer invalidate];
        self.m_noServerTimer = nil;
    }
}

- (void) noServerTimerFaired:(id)sender
{
    DLog(@"BTClientManager:noServerTimerFaired");
    [self stopSendRSSITimer];

    if (m_server &&  m_server.m_peripheral && m_server.m_connected)
    {
        return;
    }

    [self restartScan];
}

- (void) setRSSIRefreshInterval:(NSTimeInterval)interval
{
    DLog(@"BTClientManager:setRSSIRefreshInterval = [%f]", interval);
    [CustomThread syncRunBlock: ^
    {
        m_rssiRefreshInterval = interval;
        if (m_rssiRefreshInterval <= 0)
        {
            [self stopSendRSSITimer];
        }
        else
        {
            [self startSendRSSITimer];
        }
    }
    inRunLoop:[m_btManagerThread getRunLoop]];
}

- (BTServer*) getServer
{
    __block BTServer* server = nil;

    [CustomThread syncRunBlock: ^
    {
        if (m_server && m_server.m_peripheral && m_server.m_connected)
        {
            server = [m_server retain];
        }
    }
    inRunLoop:[m_btManagerThread getRunLoop]];

    return [server autorelease];
}

+ (void) setCustomLoggerBlock:(void (^)(NSString*))block
{
    if (__g_customLogBlock)
    {
        Block_release(__g_customLogBlock);
        __g_customLogBlock = nil;
    }

    if (block)
    {
        __g_customLogBlockRunLoop = CFRunLoopGetCurrent();
        __g_customLogBlock = Block_copy(block);
    }
}

@end
