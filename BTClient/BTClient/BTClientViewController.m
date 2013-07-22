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


#import "BTClientViewController.h"
#import "BTClientAppDelegate.h"


@interface BTClientLog : NSObject
{
    NSString*  m_message;
    NSDate*    m_timeStamp;
}

- (id) initWithMessage:(NSString*)msg timeStamp:(NSDate*)date;
- (NSString*) getLogWithDateFormatter:(NSDateFormatter*)dateFormatter;
- (NSString*) getMessage;

@end

@implementation BTClientLog

- (id) initWithMessage:(NSString*)msg timeStamp:(NSDate*)date
{
    if (self = [super init])
    {
        m_message = [msg retain];
        m_timeStamp = [date retain];
    }

    return self;
}

- (void) dealloc
{
    [m_message release];
    [m_timeStamp release];
    [super dealloc];
}

- (NSString*) getLogWithDateFormatter:(NSDateFormatter*)dateFormatter
{
    NSTimeInterval timeIntervalSince1970 = [m_timeStamp timeIntervalSince1970];
    int milliseconds = ((double)timeIntervalSince1970 - (long)timeIntervalSince1970) * 1000;

    NSString* logMessage = [NSString stringWithFormat:@"%@,%003d  %@", [dateFormatter stringFromDate:m_timeStamp], (int)milliseconds, m_message];
    return logMessage;
}

- (NSString*) getMessage
{
    return m_message;
}

@end


@interface BTClientViewController()
{
    id<BTClientViewControllerDelegate>    m_delegate;
    NSDateFormatter*                      m_dateFormatter;
    NSLock*                               m_lock;
    NSMutableArray*                       m_logQueue;
}

@end


@implementation BTClientViewController

- (void) viewDidLoad
{
    [super viewDidLoad];

	// Do any additional setup after loading the view, typically from a nib.
    if (!m_dateFormatter)
    {
        m_dateFormatter = [[NSDateFormatter alloc] init];
        [m_dateFormatter setDateFormat:@"dd-MMM-YYYY HH:mm:ss"];
        NSLocale* en_us_locale = [[[NSLocale alloc] initWithLocaleIdentifier:@"en_US"] autorelease];
        [m_dateFormatter setLocale:en_us_locale];
    }

    if (!m_lock)
    {
        m_lock = [[NSLock alloc] init];
    }

    if (!m_logQueue)
    {
        m_logQueue = [[NSMutableArray alloc] init];
    }

    [m_sendTextField setDelegate:self];
}

- (void) dealloc
{
    [m_logQueue release];
    [m_dateFormatter release];
    [m_lock release];
    [super dealloc];
}

- (void) setDelegate:(id<BTClientViewControllerDelegate>)delegate
{
    m_delegate = delegate;
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    [m_delegate clientViewController:self sendString:[textField text]];
    [textField resignFirstResponder];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [textField resignFirstResponder];
    return YES;
}

- (void) setBTStateString:(NSString*)string
{
    [m_btStateLabel setText:string];
}

- (void) setServerString:(NSString*)string
{
    [m_serverTextView setText:string];
}

- (void) log:(NSString*)string
{
    [m_lock lock];

    BTClientLog* log = [[[BTClientLog alloc] initWithMessage:string timeStamp:[NSDate date]] autorelease];
    [m_logQueue addObject:log];

    [m_lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^
    {
        [m_lock lock];

        NSArray* logs = [NSArray arrayWithArray:m_logQueue];
        [m_logQueue removeAllObjects];

        [m_lock unlock];

        if ([logs count] == 0)
        {
            return;
        }

        NSMutableString* logString = [NSMutableString string];

        for (BTClientLog* log in logs)
        {
            [logString appendFormat:@"%@\n", [log getLogWithDateFormatter:m_dateFormatter]];
        }

        {
            const char* consoleLog = [logString UTF8String];
            if (consoleLog)
            {
                printf("%s", consoleLog);
            }
        }

        NSMutableString* newText = [NSMutableString stringWithString:m_logTextView.text];
        [newText appendFormat:@"\n%@", logString];
        [m_logTextView setText:newText];

        if ([newText length] > 0)
        {
            [m_logTextView scrollRangeToVisible:NSMakeRange([newText length] - 1, 1)];
        }
    });
}

- (void) enableSendTextField:(BOOL)enable
{
    [m_sendTextField setEnabled:enable];
    m_sendTextField.backgroundColor = enable ? [UIColor whiteColor] : [UIColor lightGrayColor];
}

- (IBAction) clearLogButtonPressed:(id)sender
{
    [m_logTextView setText:@""];
}

@end
