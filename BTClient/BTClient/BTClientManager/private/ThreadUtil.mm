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

#import "ThreadUtil.h"


@interface CustomThread()

- (void) start;
- (void) doThread;
- (void) stop;

@end


class CustomThreadCallback
{
public:
    CustomThreadCallback(CustomThread* delegate) :
        m_delegate(delegate) {}

    virtual ~CustomThreadCallback(void)
    {
        m_delegate = nil;
    }

    void custom_thread_callback_handler(void)
    {
        if (m_delegate)
        {
            [m_delegate doThread];
        }
    }

    static void* custom_thread_callback(void* context)
    {
        @autoreleasepool
        {
            CustomThreadCallback* callback = static_cast<CustomThreadCallback*>(context);
            if (callback)
            {
                 callback->custom_thread_callback_handler();
            }

            return NULL;
        }
    }

    void perform_stop_signal_callback_handler(void)
    {
        if (m_delegate)
        {
            [m_delegate stop];
        }
    }

    static void perform_stop_signal_callback(void* context)
    {
        @autoreleasepool
        {
            CustomThreadCallback* callback = static_cast<CustomThreadCallback*>(context);
            if (callback)
            {
                 callback->perform_stop_signal_callback_handler();
            }
        }
    }

private:
     CustomThread*     m_delegate;
};


@interface CustomThread()
{
    pthread_t                   m_thread;
    CFRunLoopRef                m_runLoop;
    bool                        m_shutdown;
    dispatch_semaphore_t        m_startupCondition;
    CFRunLoopSourceRef          m_stopSignalSource;
    void*                       m_callback;
}

@end


@implementation CustomThread

- (id) init
{
    if (self = [super init])
    {
        [self start];
    }
    return self;
}

- (void) dealloc
{
    [self join];
    [super dealloc];
}

- (void) start
{
    m_startupCondition = dispatch_semaphore_create(0);
    m_callback = static_cast<void*>(new CustomThreadCallback(self));

    pthread_create(&m_thread, NULL, CustomThreadCallback::custom_thread_callback, m_callback);

    dispatch_semaphore_wait(m_startupCondition, DISPATCH_TIME_FOREVER);
}

- (void) stop
{
    if (m_runLoop)
    {
        CFRunLoopStop(m_runLoop);
    }
}

- (void) doThread
{
    m_runLoop = CFRunLoopGetCurrent();

    CFRunLoopSourceContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.version = 0;
    ctx.info = m_callback;
    ctx.perform = &CustomThreadCallback::perform_stop_signal_callback;

    m_stopSignalSource = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx);
    CFRunLoopAddSource(m_runLoop, m_stopSignalSource, kCFRunLoopDefaultMode);

    dispatch_semaphore_signal(m_startupCondition);

    while (!m_shutdown)
    {
        @autoreleasepool
        {
            SInt32 code = CFRunLoopRunInMode(kCFRunLoopDefaultMode, 10 /* 10 secs */, FALSE);
            if (code == kCFRunLoopRunFinished || code == kCFRunLoopRunStopped)
            {
                break;
            }
        }
    }
}

- (CFRunLoopRef) getRunLoop
{
    return m_runLoop;
}

- (void) join
{
    if (m_thread)
    {
        m_shutdown = true;

        CFRunLoopSourceSignal(m_stopSignalSource);
        CFRunLoopWakeUp(m_runLoop);

        pthread_join(m_thread, NULL);

        m_thread = NULL;
        m_runLoop = NULL;
        m_shutdown = false;
    }

    if (m_startupCondition)
    {
        dispatch_release(m_startupCondition);
        m_startupCondition = NULL;
    }

    if (m_stopSignalSource)
    {
        CFRelease(m_stopSignalSource);
        m_stopSignalSource = NULL;
    }

    if (m_callback)
    {
        delete static_cast<CustomThreadCallback*>(m_callback);
        m_callback = NULL;
    }
}

+ (void) asyncRunBlock:(void (^)(void))block inRunLoop:(CFRunLoopRef)runLoop
{
    if (CFRunLoopGetCurrent() != runLoop)
    {
        CFRunLoopPerformBlock(runLoop, kCFRunLoopDefaultMode,^
        {
            block();
        });

        CFRunLoopWakeUp(runLoop);
    }
    else
    {
        block();
    }
}

+ (void) syncRunBlock:(void (^)(void))block inRunLoop:(CFRunLoopRef)runLoop
{
    if (CFRunLoopGetCurrent() != runLoop)
    {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        CFRunLoopPerformBlock(runLoop, kCFRunLoopCommonModes,^
        {
            block();
            dispatch_semaphore_signal(semaphore);
        });

        CFRunLoopWakeUp(runLoop);
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        dispatch_release(semaphore);
    }
    else
    {
        block();
    }
}

@end


CustomLock::CustomLock(NSLock* lock)
{
    m_lock = nil;

    if (lock)
    {
        m_lock = [lock retain];
        [m_lock lock];
    }
}

CustomLock::~CustomLock()
{
    if (m_lock)
    {
        [m_lock unlock];
        [m_lock release];
    }
}
