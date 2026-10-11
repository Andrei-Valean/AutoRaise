/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "WindowPin.h"
#import "WindowFinder.h"

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

// How often, while anything is pinned, to look at what is in front of it. One
// window list from the window server each time, which costs about a millisecond.
// Clicks and application switches ask for an extra look straight away, so this
// only has to catch what nobody announced: a window opening on top, a drag.
#define AR_PIN_POLL_SECONDS 0.1
// An overlap thinner than this is not covering anything a person would miss:
// shadows that report as frames, drag images, a neighbour sharing an edge.
#define AR_PIN_MIN_OVERLAP 4.0
// Asking an application which of its windows it is working in costs a round
// trip, and the answer only matters while one of its windows overlaps the pin.
#define AR_PIN_IN_USE_CACHE_SECONDS 0.5

BOOL ARWindowPinVerbose = NO;

static CGRect ARBoundsOf(NSDictionary *window) {
    NSDictionary *bounds = window[(__bridge id) kCGWindowBounds];
    return CGRectMake([bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
                      [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue]);
}

// Whether the window server still knows the window at all, on screen or not.
// The id goes in as a raw pointer sized value, which is what this call expects.
static BOOL ARWindowStillExists(CGWindowID windowId) {
    const void *ids[1] = { (const void *) (uintptr_t) windowId };
    CFArrayRef array = CFArrayCreate(kCFAllocatorDefault, ids, 1, NULL);
    NSArray *description = (NSArray *) CFBridgingRelease(CGWindowListCreateDescriptionFromArray(array));
    CFRelease(array);
    return description.count > 0;
}

// The accessibility API and the window server count from the top left of the
// primary display; NSWindow counts from its bottom left.
static NSRect ARAppKitFrame(CGRect frame) {
    NSScreen *primary = NSScreen.screens.firstObject;
    CGFloat top = primary ? NSMaxY(primary.frame) : 0;
    return NSMakeRect(frame.origin.x, top - CGRectGetMaxY(frame), frame.size.width, frame.size.height);
}

static CGFloat ARBackingScaleFor(CGRect frame) {
    NSRect appKit = ARAppKitFrame(frame);
    NSPoint centre = NSMakePoint(NSMidX(appKit), NSMidY(appKit));
    for (NSScreen *screen in NSScreen.screens) {
        if (NSPointInRect(centre, screen.frame)) { return screen.backingScaleFactor; }
    }
    return NSScreen.mainScreen.backingScaleFactor ?: 2;
}

static NSString *ARNameOfWindow(AXUIElementRef window, pid_t pid) {
    NSString *app = [NSRunningApplication runningApplicationWithProcessIdentifier: pid].localizedName;
    CFTypeRef title = NULL;
    AXUIElementCopyAttributeValue(window, kAXTitleAttribute, &title);
    NSString *text = (NSString *) CFBridgingRelease(title);
    if (![text isKindOfClass: [NSString class]] || !text.length) { return app ?: @"a window"; }
    return app ? [NSString stringWithFormat: @"%@: %@", app, text] : text;
}

//------------------------------------------------ the copy ------------------------------------------------

@interface ARPinCopyView : NSView
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) void (^onClick)(void);
@property (nonatomic, copy) void (^onUnpin)(void);
@end

@implementation ARPinCopyView

// The panel never becomes key, so without this the first click would only
// focus it, and a second click would be needed to do anything.
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (void)mouseDown:(NSEvent *)event {
    if (event.modifierFlags & NSEventModifierFlagControl) {
        [self rightMouseDown: event];
        return;
    }
    if (self.onClick) { self.onClick(); }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSMenu *menu = [[NSMenu alloc] init];
    NSMenuItem *unpin = [menu addItemWithTitle: [NSString stringWithFormat: @"Unpin %@", self.name]
                                        action: @selector(unpin:) keyEquivalent: @""];
    unpin.target = self;
    [NSMenu popUpContextMenu: menu withEvent: event forView: self];
}

- (void)unpin:(id)sender {
    if (self.onUnpin) { self.onUnpin(); }
}

@end

//------------------------------------------------- one pin ------------------------------------------------

@interface ARPinnedWindow () <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, readwrite) BOOL showingCopy;
@property (nonatomic, readonly) CGRect frame;
@property (nonatomic, copy) void (^onStopped)(NSError *error);
@property (nonatomic, copy) void (^onClick)(void);
@property (nonatomic, copy) void (^onUnpin)(void);
@end

@implementation ARPinnedWindow {
    AXUIElementRef _window;
    NSPanel *_panel;
    ARPinCopyView *_view;
    SCStream *_stream;
    SCStreamConfiguration *_configuration;
    dispatch_queue_t _frames;
    CGSize _streamSize;      // in pixels
    BOOL _havePicture;       // nothing is shown until the first frame has arrived
    BOOL _wantsCopy;         // covered, so the copy should be up once there is a picture
    BOOL _stopped;
    BOOL _inUse;
    NSTimeInterval _inUseCheckedAt;
}

- (instancetype)initWithWindow:(AXUIElementRef)window windowId:(CGWindowID)windowId
                           pid:(pid_t)pid frame:(CGRect)frame {
    if ((self = [super init])) {
        _window = (AXUIElementRef) CFRetain(window);
        _windowId = windowId;
        _pid = pid;
        _frame = frame;
        _name = [ARNameOfWindow(window, pid) copy];
        _frames = dispatch_queue_create("autoraise.pin.frames", DISPATCH_QUEUE_SERIAL);

        _view = [[ARPinCopyView alloc] initWithFrame: NSZeroRect];
        _view.wantsLayer = YES;
        _view.layer.contentsGravity = kCAGravityResizeAspect;
        _view.name = _name;
        // Through the pin rather than straight to whoever handles it, so the
        // view never keeps the pin alive.
        __weak ARPinnedWindow *weakSelf = self;
        _view.onClick = ^{
            ARPinnedWindow *pin = weakSelf;
            if (pin.onClick) { pin.onClick(); }
        };
        _view.onUnpin = ^{
            ARPinnedWindow *pin = weakSelf;
            if (pin.onUnpin) { pin.onUnpin(); }
        };

        // A non-activating panel: clicking the copy must not make AutoRaise the
        // frontmost application, or the real window could never come forward.
        _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10)
            styleMask: NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing: NSBackingStoreBuffered defer: NO];
        _panel.opaque = NO;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.hasShadow = YES;
        // One above the focus ring, which is clipped to the visible part of the
        // window it marks and does not know about this copy.
        _panel.level = NSFloatingWindowLevel + 1;
        _panel.releasedWhenClosed = NO;
        _panel.hidesOnDeactivate = NO;
        _panel.becomesKeyOnlyIfNeeded = YES;
        // No space behaviour: the copy stays on the desktop the window is on,
        // and is taken down whenever the window is not on screen anyway.
        _panel.collectionBehavior = NSWindowCollectionBehaviorIgnoresCycle |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
        _panel.contentView = _view;
    }
    return self;
}

- (void)dealloc {
    if (_window) { CFRelease(_window); }
}

- (AXUIElementRef)window { return _window; }

- (SCStreamConfiguration *)configurationForFrame:(CGRect)frame {
    SCStreamConfiguration *configuration = [[SCStreamConfiguration alloc] init];
    CGFloat scale = ARBackingScaleFor(frame);
    configuration.width = (size_t) MAX(1, round(frame.size.width * scale));
    configuration.height = (size_t) MAX(1, round(frame.size.height * scale));
    configuration.pixelFormat = kCVPixelFormatType_32BGRA;
    configuration.showsCursor = NO;
    configuration.minimumFrameInterval = CMTimeMake(1, 60);
    configuration.queueDepth = 4;
    configuration.ignoreShadowsSingleWindow = YES;
    configuration.captureResolution = SCCaptureResolutionBest;
    // Sheets would widen the picture past the window's frame, and the stream
    // would then shrink the lot to fit; the copy has to match the window.
    configuration.includeChildWindows = NO;
    return configuration;
}

- (void)startCapturing:(SCWindow *)window {
    SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow: window];
    _configuration = [self configurationForFrame: _frame];
    _streamSize = CGSizeMake(_configuration.width, _configuration.height);
    _stream = [[SCStream alloc] initWithFilter: filter configuration: _configuration delegate: self];

    NSError *error = nil;
    if (![_stream addStreamOutput: self type: SCStreamOutputTypeScreen
               sampleHandlerQueue: _frames error: &error]) {
        [self stoppedWithError: error];
        return;
    }
    __weak ARPinnedWindow *weakSelf = self;
    [_stream startCaptureWithCompletionHandler: ^(NSError *startError) {
        if (!startError) { return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stoppedWithError: startError]; });
    }];
}

- (void)stop {
    if (_stopped) { return; }
    _stopped = YES;
    [_panel orderOut: nil];
    self.showingCopy = NO;
    SCStream *stream = _stream;
    _stream = nil;
    [stream stopCaptureWithCompletionHandler: ^(NSError *error) {
        // Removed only once stopped: the stream holds its output, which is this
        // pin, and keeping that link would keep the pin alive for good.
        [stream removeStreamOutput: self type: SCStreamOutputTypeScreen error: nil];
    }];
}

- (void)stoppedWithError:(NSError *)error {
    if (_stopped) { return; }
    if (self.onStopped) { self.onStopped(error); }
}

// SCStreamDelegate, on some queue of its own.
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    __weak ARPinnedWindow *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf stoppedWithError: error]; });
}

// SCStreamOutput, on the frames queue. Only finished frames carry a picture;
// the others say nothing changed.
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) { return; }
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (!attachments || CFArrayGetCount(attachments) == 0) { return; }
    NSDictionary *info = (__bridge NSDictionary *) CFArrayGetValueAtIndex(attachments, 0);
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) { return; }

    CVImageBufferRef pixels = CMSampleBufferGetImageBuffer(sampleBuffer);
    IOSurfaceRef surface = pixels ? CVPixelBufferGetIOSurface(pixels) : NULL;
    if (!surface) { return; }
    // The layer shows the surface directly, without copying the pixels; holding
    // it here keeps the stream from recycling it until the main thread has it.
    id picture = (__bridge id) surface;
    __weak ARPinnedWindow *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf show: picture]; });
}

- (void)show:(id)picture {
    if (_stopped) { return; }
    [CATransaction begin];
    [CATransaction setDisableActions: YES];
    _view.layer.contents = picture;
    [CATransaction commit];
    if (!_havePicture) {
        _havePicture = YES;
        [self updateCopy];
        // The shadow follows the shape of what is drawn, rounded corners
        // included, so it is worked out again once there is something drawn.
        [_panel invalidateShadow];
    }
}

// Called with the on screen window list, front to back. Returns NO when the
// window has gone for good, which ends the pin.
- (BOOL)refreshFrom:(NSArray<NSDictionary *> *)windows {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < windows.count; i++) {
        if ([windows[i][(__bridge id) kCGWindowNumber] unsignedIntValue] == _windowId) {
            index = i;
            break;
        }
    }
    if (index == NSNotFound) {
        // Minimised, hidden, on another desktop, or closed. Only closed ends it:
        // the others come back, and the pin with them.
        if (!ARWindowStillExists(_windowId)) { return NO; }
        _wantsCopy = NO;
        [self updateCopy];
        return YES;
    }

    CGRect frame = ARBoundsOf(windows[index]);
    if (!CGRectEqualToRect(frame, _frame)) {
        BOOL resized = !CGSizeEqualToSize(frame.size, _frame.size);
        _frame = frame;
        [_panel setFrame: ARAppKitFrame(frame) display: NO];
        if (resized) { [self resizeStream]; }
    }
    _wantsCopy = [self coveredBy: [windows subarrayWithRange: NSMakeRange(0, index)]];
    [self updateCopy];
    return YES;
}

// Everything in the list comes before the pinned window, so it is all in front.
- (BOOL)coveredBy:(NSArray<NSDictionary *> *)inFront {
    pid_t own = getpid();
    BOOL ownApplicationInFront = NO;
    for (NSDictionary *window in inFront) {
        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
        pid_t pid = [window[(__bridge id) kCGWindowOwnerPID] intValue];
        if (pid == own) { continue; }
        NSNumber *alpha = window[(__bridge id) kCGWindowAlpha];
        if (alpha && alpha.doubleValue <= 0.01) { continue; }
        CGRect overlap = CGRectIntersection(ARBoundsOf(window), _frame);
        if (CGRectIsNull(overlap) || overlap.size.width < AR_PIN_MIN_OVERLAP ||
            overlap.size.height < AR_PIN_MIN_OVERLAP) { continue; }
        if (pid != _pid) { return YES; }
        ownApplicationInFront = YES;
    }
    // Sheets, popovers and completion lists belong to the pinned window and sit
    // in front of it while you work in it. Another window of the same
    // application covers it only when the pinned one is not the one in use.
    return ownApplicationInFront && ![self isInUseInItsApplication];
}

// In use means the application's main window. Not the focused one: with a
// sheet up, the sheet has the keyboard and the window it belongs to is still
// main. Applications that never name a main window fall back to focus.
- (BOOL)isInUseInItsApplication {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _inUseCheckedAt < AR_PIN_IN_USE_CACHE_SECONDS) { return _inUse; }
    _inUseCheckedAt = now;
    AXUIElementRef window = ARCopyActivatedWindow(_pid);
    _inUse = window && ARWindowID(window) == _windowId;
    if (window) { CFRelease(window); }
    return _inUse;
}

- (void)updateCopy {
    BOOL show = _wantsCopy && _havePicture && !_stopped;
    if (show == _panel.isVisible) { return; }
    if (show) {
        [_panel setFrame: ARAppKitFrame(_frame) display: NO];
        // Not the frontmost application, so plain orderFront would be ignored.
        [_panel orderFrontRegardless];
    } else {
        [_panel orderOut: nil];
    }
    self.showingCopy = show;
    if (ARWindowPinVerbose) {
        NSLog(@"Pin %@: %@", _name, show ? @"covered, showing the copy" : @"in view, copy hidden");
    }
}

- (void)resizeStream {
    if (!_stream) { return; }
    SCStreamConfiguration *configuration = [self configurationForFrame: _frame];
    CGSize size = CGSizeMake(configuration.width, configuration.height);
    if (CGSizeEqualToSize(size, _streamSize)) { return; }
    _streamSize = size;
    _configuration = configuration;
    [_stream updateConfiguration: configuration completionHandler: ^(NSError *error) {
        if (error && ARWindowPinVerbose) { NSLog(@"Pin resize refused: %@", error.localizedDescription); }
    }];
    [_panel invalidateShadow];
}

@end

//------------------------------------------------- all pins -----------------------------------------------

@implementation ARWindowPins {
    __weak id<ARWindowPinsDelegate> _delegate;
    NSMutableArray<ARPinnedWindow *> *_pinned;
    // Window ids waiting on ScreenCaptureKit, so a second press does not pin twice.
    NSMutableSet<NSNumber *> *_starting;
    NSTimer *_poll;
}

- (instancetype)initWithDelegate:(id<ARWindowPinsDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _pinned = [NSMutableArray array];
        _starting = [NSMutableSet set];
    }
    return self;
}

- (NSArray<ARPinnedWindow *> *)pins { return [_pinned copy]; }

- (NSString *)togglePinOf:(AXUIElementRef)window {
    CGWindowID windowId = ARWindowID(window);
    if (windowId == kCGNullWindowID) {
        return @"That window has no id AutoRaise can read, so it cannot be pinned";
    }
    for (ARPinnedWindow *pin in _pinned) {
        if (pin.windowId == windowId) {
            [self unpin: pin];
            return [NSString stringWithFormat: @"Unpinned %@", pin.name];
        }
    }
    if ([_starting containsObject: @(windowId)]) { return @"Already pinning that window"; }

    if (!CGPreflightScreenCaptureAccess()) {
        // The request is what puts AutoRaise on the list in System Settings; the
        // first time it also asks. Opening the page covers every later time,
        // when macOS no longer asks by itself.
        CGRequestScreenCaptureAccess();
        [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"]];
        return @"Pinning needs the Screen Recording permission. Allow AutoRaise in System "
                "Settings, then pin again; macOS may ask to reopen AutoRaise first";
    }

    pid_t pid = 0;
    AXUIElementGetPid(window, &pid);
    CGRect frame = CGRectZero;
    if (!pid || !ARWindowFrame(window, &frame)) { return @"That window did not say where it is"; }

    ARPinnedWindow *pin = [[ARPinnedWindow alloc] initWithWindow: window windowId: windowId
                                                             pid: pid frame: frame];
    [_starting addObject: @(windowId)];
    __weak ARWindowPins *weakSelf = self;
    [SCShareableContent getShareableContentExcludingDesktopWindows: YES onScreenWindowsOnly: YES
        completionHandler: ^(SCShareableContent *content, NSError *error) {
        SCWindow *found = nil;
        for (SCWindow *candidate in content.windows) {
            if (candidate.windowID == windowId) { found = candidate; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf start: pin with: found error: error];
        });
    }];
    return [NSString stringWithFormat: @"Pinning %@", pin.name];
}

- (void)start:(ARPinnedWindow *)pin with:(SCWindow *)window error:(NSError *)error {
    [_starting removeObject: @(pin.windowId)];
    if (!window) {
        NSLog(@"Cannot pin %@: %@", pin.name,
              error.localizedDescription ?: @"screen capture does not list that window");
        return;
    }
    __weak ARWindowPins *weakSelf = self;
    __weak ARPinnedWindow *weakPin = pin;
    pin.onStopped = ^(NSError *stopError) {
        ARPinnedWindow *stopped = weakPin;
        if (!stopped) { return; }
        NSLog(@"Unpinned %@: %@", stopped.name,
              stopError.localizedDescription ?: @"screen capture stopped");
        [weakSelf unpin: stopped];
    };
    pin.onClick = ^{
        ARPinnedWindow *clicked = weakPin;
        if (clicked) { [weakSelf pinnedWindowWasClicked: clicked]; }
    };
    pin.onUnpin = ^{
        ARPinnedWindow *unpinned = weakPin;
        if (!unpinned) { return; }
        NSLog(@"Unpinned %@", unpinned.name);
        [weakSelf unpin: unpinned];
    };
    [_pinned addObject: pin];
    [pin startCapturing: window];
    NSLog(@"Pinned %@", pin.name);
    [self startPolling];
    [self refresh];
}

- (void)unpin:(ARPinnedWindow *)pin {
    [pin stop];
    [_pinned removeObject: pin];
    if (!_pinned.count) { [self stopPolling]; }
}

- (void)unpinAll {
    for (ARPinnedWindow *pin in [_pinned copy]) { [self unpin: pin]; }
}

- (nullable ARPinnedWindow *)pinShowingCopyAt:(CGPoint)point {
    // The most recently pinned copy was ordered in last, so it is on top.
    for (ARPinnedWindow *pin in _pinned.reverseObjectEnumerator) {
        if (pin.showingCopy && CGRectContainsPoint(pin.frame, point)) { return pin; }
    }
    return nil;
}

- (BOOL)isShowingCopyOf:(CGWindowID)windowId {
    for (ARPinnedWindow *pin in _pinned) {
        if (pin.windowId == windowId) { return pin.showingCopy; }
    }
    return NO;
}

- (void)pinnedWindowWasClicked:(ARPinnedWindow *)pin {
    [_delegate pinnedWindowWasClicked: pin];
    [self stackingMayHaveChanged];
}

- (void)stackingMayHaveChanged {
    if (!_pinned.count) { return; }
    [self refresh];
    // Whatever was clicked or activated takes a moment to come forward.
    __weak ARWindowPins *weakSelf = self;
    for (NSNumber *delay in @[@0.04, @0.15, @0.35]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
    }
}

- (void)refresh {
    if (!_pinned.count) { return; }
    NSArray *windows = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (ARPinnedWindow *pin in [_pinned copy]) {
        if (![pin refreshFrom: windows ?: @[]]) {
            NSLog(@"Unpinned %@: the window closed", pin.name);
            [self unpin: pin];
        }
    }
}

- (void)startPolling {
    // A stream that fails to start unpins before this runs.
    if (_poll || !_pinned.count) { return; }
    _poll = [NSTimer timerWithTimeInterval: AR_PIN_POLL_SECONDS target: self
                                  selector: @selector(pollFired:) userInfo: nil repeats: YES];
    _poll.tolerance = AR_PIN_POLL_SECONDS / 4;
    // Common modes, so a pin keeps up while a menu is open or a window is dragged.
    [[NSRunLoop mainRunLoop] addTimer: _poll forMode: NSRunLoopCommonModes];
}

- (void)stopPolling {
    [_poll invalidate];
    _poll = nil;
}

- (void)pollFired:(NSTimer *)timer { [self refresh]; }

@end
