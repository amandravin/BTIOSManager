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


#import "BTClientAppDelegate.h"


#define TRANSFER_SERVICE_UUID           @"AA5F3F6D-6991-485C-A612-60AED33519BA"
#define TRANSFER_CHARACTERISTIC_UUID    @"FAF1E8BC-062C-4974-B4B0-F55DF854F41A"


#define DLog(__FORMAT__, ...)                                                               \
do                                                                                          \
{                                                                                           \
    NSString* btc_ad_dlog_string = [NSString stringWithFormat:(__FORMAT__), ##__VA_ARGS__]; \
    [[BTClientAppDelegate sharedInstance] log:btc_ad_dlog_string];                          \
}                                                                                           \
while(0);                                                                                   \


@interface BTClientAppDelegate()

@property (nonatomic, retain) BTServer* m_server;

- (void) logInfo;

@end


@implementation BTClientAppDelegate

@synthesize m_server;

- (void) dealloc
{
    [m_server release];
    [m_btClientManager release];
    [_window release];
    [_viewController release];
    [super dealloc];
}

- (BOOL) application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)launchOptions
{
    self.window = [[[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]] autorelease];

    // Override point for customization after application launch.
    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPhone)
    {
        self.viewController = [[[BTClientViewController alloc] initWithNibName:@"BTClientViewController_iPhone" bundle:nil] autorelease];
    }
    else
    {
        self.viewController = [[[BTClientViewController alloc] initWithNibName:@"BTClientViewController_iPad" bundle:nil] autorelease];
    }

    self.window.rootViewController = self.viewController;
    [self.window makeKeyAndVisible];

    DLog(@"application:didFinishLaunchingWithOptions");

    [_viewController setDelegate:self];
    [_viewController enableSendTextField:NO];

    [BTClientManager setCustomLoggerBlock: ^(NSString* message)
    {
        DLog(message, nil);
    }];

    m_btClientManager = [[BTClientManager alloc] initWithDelegate:self serviceUUID:TRANSFER_SERVICE_UUID characteristicUUID:TRANSFER_CHARACTERISTIC_UUID];

    return YES;
}

- (void) applicationWillResignActive:(UIApplication*)application
{
    DLog(@"applicationWillResignActive");
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void) applicationDidEnterBackground:(UIApplication*)application
{
    DLog(@"applicationDidEnterBackground");
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later. 
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void) applicationWillEnterForeground:(UIApplication*)application
{
    DLog(@"applicationWillEnterForeground");
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void) applicationDidBecomeActive:(UIApplication*)application
{
    DLog(@"applicationDidBecomeActive");
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void) applicationWillTerminate:(UIApplication*)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    [m_btClientManager release];
    m_btClientManager = nil;
}

- (void) btClientManager:(id)btManager didStart:(BOOL)start
{
    [_viewController setBTStateString:(start ? @"BT CLIENT: STARTED" : @"BT CLIENT: STOPPED")];
    [self logInfo];
}

- (void) btClientManager:(id)btManager didConnectToServer:(BTServer*)server
{
    self.m_server = server;
    [m_server setDelegate:self];
    [self logInfo];
}

- (void) btClientManager:(id)btManager didDisconnectFromServer:(BTServer*)server
{
    self.m_server = nil;
    [self logInfo];
}

- (void) btClientManager:(id)btManager didUpdateRSSI:(NSInteger)rssi
{
    [self logInfo];
}

- (void) btServer:(id)btServer didSendData:(NSData*)data success:(BOOL)success
{
    if (success)
    {
        DLog(@"Send data success");
    }
    else
    {
        DLog(@"Error. Send data failed: [%@]", data);
    }
}

- (void) clientViewController:(id)viewController sendString:(NSString*)string;
{
    DLog(@"clientViewController:sendString = [%@]", string);

    if ([string length] == 0)
    {
        return;
    }

    if (m_server)
    {
        NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
        [m_server sendData:data];
    }
}

- (void) logInfo
{
    if (!m_server)
    {
        [_viewController setServerString:@""];
        [_viewController enableSendTextField:NO];
        return;
    }

    NSString* serverString = [NSString stringWithFormat:@"NAME[%@], RSSI[%d], UUID[%@]", [m_server getName], [m_server getRSSI], [m_server getUUID]];
    [_viewController setServerString:serverString];
    [_viewController enableSendTextField:YES];
}

+ (BTClientAppDelegate*) sharedInstance
{
    return (BTClientAppDelegate*)[[UIApplication sharedApplication] delegate];
}

- (void) log:(NSString*)log
{
    [_viewController log:log];
}

@end
