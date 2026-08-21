/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>

#include <fcntl.h>
#include <unistd.h>

#import <ServiceManagement/ServiceManagement.h>

#import "Config.h"
#import "FocusRing.h"
#import "MenuBar.h"
#import "Policy.h"
#import "Quirks.h"
#import "SettingsWindow.h"
#import "WindowFinder.h"

#define AUTORAISE_VERSION "6.0"

// An activate delay of about 10 milliseconds is just high enough to ensure we
// always find the latest focused (main) window.
#define ACTIVATE_DELAY_MS 10
#define SCALE_DELAY_MS 400                       // when the mouse starts growing
#define SCALE_DURATION_MS (SCALE_DELAY_MS + 600) // and when it stops
#define TASK_SWITCHER_MODIFIER_KEY kCGEventFlagMaskCommand
#define PERMISSION_RETRY_SECONDS 2.0

// How many quiet evaluations before the fast timer stands down and the
// heartbeat takes over again.
#define IDLE_TICKS_BEFORE_SLEEP 4

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);

#if SKYLIGHT_AVAILABLE
#define kCPSUserGenerated 0x200
extern "C" CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern "C" CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
#endif

//----------------------------------------yabai focus only methods------------------------------------------

#if SKYLIGHT_AVAILABLE
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
static void window_manager_make_key_window(ProcessSerialNumber *_window_psn, uint32_t window_id) {
    uint8_t bytes[0xf8] = {0};
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(_window_psn, bytes);

    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(_window_psn, bytes);
}

static void window_manager_focus_window_without_raise(
    ProcessSerialNumber *_window_psn, uint32_t window_id,
    ProcessSerialNumber *_focused_window_psn, uint32_t focused_window_id, BOOL verbose
) {
    if (verbose) { NSLog(@"Focus"); }
    if (_focused_window_psn) {
        Boolean same_process = false;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        SameProcess(_window_psn, _focused_window_psn, &same_process);
#pragma clang diagnostic pop
        if (same_process) {
            if (verbose) { NSLog(@"Same process"); }
            uint8_t bytes[0xf8] = {0};
            bytes[0x04] = 0xf8;
            bytes[0x08] = 0x0d;

            bytes[0x8a] = 0x02;
            memcpy(bytes + 0x3c, &focused_window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_focused_window_psn, bytes);

            // @hack
            // Artificially delay the activation. This is necessary because some
            // applications appear to be confused if both of the events appear
            // instantaneously.
            usleep(10000);

            bytes[0x8a] = 0x01;
            memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_window_psn, bytes);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//------------------------------------------------controller------------------------------------------------

@interface ARController : NSObject <ARMenuBarDelegate, ARSettingsDelegate>
- (instancetype)initWithConfig:(ARConfig *)config;
- (void)handleTappedEvent:(CGEventRef)event ofType:(CGEventType)type;
- (void)windowDestroyed:(CGWindowID)windowId;
- (void)hideFocusRing;
- (void)followRingedWindow;
- (void)shutDown;
@end

@implementation ARController {
    ARConfig *_config;
    ARQuirks *_quirks;
    ARMenuBar *_menuBar;
    ARSettingsWindowController *_settingsWindow;
    ARFocusRing *_focusRing;
    BOOL _enabled;

    // Mouse tracking. _point is fed by the event tap, so a still cursor needs no
    // timer at all; the heartbeat re-reads it in case the tap missed a move.
    CGPoint _point;            // where the mouse is now
    CGPoint _evaluatedPoint;   // where it was at the previous evaluation
    CGPoint _correctedPoint;
    BOOL _havePoint;
    BOOL _propagateMouseMoved;
    CGEventFlags _flags;

    // Delay and repeat bookkeeping, see Policy.h.
    ARDelayState _delay;
    int _idleTicks;
    int _ignoreTicks;
    BOOL _spaceHasChanged;
    BOOL _appWasActivated;
    BOOL _activatedByTaskSwitcher;

    CGWindowID _previousWindowId;
    CGWindowID _lastDestroyedWindowId;

    // The destroyed-window observer, kept with its run loop source so both can
    // be taken down again. Releasing the observer alone leaks it: the run loop
    // holds the source, and the source holds the observer.
    AXObserverRef _observer;
    CFRunLoopSourceRef _observerSource;
    AXUIElementRef _observedWindow;

    AXUIElementRef _lastFocusedWindow;
    pid_t _lastFocusedWindowPid;
    AXObserverRef _ringObserver;
    CFRunLoopSourceRef _ringObserverSource;
    AXUIElementRef _ringWindow;
    pid_t _ringPid;
    AXUIElementRef _previousFinderWindow;

    NSTimer *_fastTimer;
    NSTimer *_heartbeatTimer;
    NSTimer *_permissionTimer;
    CFMachPortRef _eventTap;
    CFRunLoopSourceRef _eventTapSource;
    dispatch_source_t _configWatcher;

    float _systemCursorScale;
    BOOL _cursorScaleChanged;
}

static ARController *controller = nil;

//------------------------------------------------ lifecycle -----------------------------------------------

- (instancetype)initWithConfig:(ARConfig *)config {
    if ((self = [super init])) {
        _config = config;
        _enabled = config.enabled;
        _delay = ARResetDelay();
        _previousWindowId = kCGNullWindowID;
        _lastDestroyedWindowId = kCGNullWindowID;
        controller = self;

        NSError *error = nil;
        NSString *quirksPath = ARQuirksUserFilePath();
        _quirks = ARQuirksLoad(quirksPath, &error);
        if (error) { NSLog(@"Ignoring %@: %@", quirksPath, error.localizedDescription); }
        else if (quirksPath) { printf("Quirks from %s\n", quirksPath.UTF8String); }

        ARWindowFinderInit(_config.verbose);
        ARFocusRingVerbose = _config.verbose;
        _focusRing = [[ARFocusRing alloc] init];
        _focusRing.color = _config.focusRingColor;
        _focusRing.style = _config.focusRingStyle;
        CGSGetCursorScale(CGSMainConnectionID(), &_systemCursorScale);
        if (_config.verbose) { NSLog(@"System cursor scale: %f", _systemCursorScale); }

        [self registerNotifications];
        [self startEventTap];
        [self startTimers];
        [self watchConfigFile];
        if (_config.menuBarIcon) { _menuBar = [[ARMenuBar alloc] initWithDelegate: self]; }
        if (!AXIsProcessTrusted()) { [self startPermissionWatch]; }
    }
    return self;
}

// Anything that must be undone before the process goes away, however it goes.
- (void)shutDown {
    [self hideFocusRing];
    [self restoreCursorScale];
    [_menuBar remove];
    _menuBar = nil;
}

- (void)restoreCursorScale {
    if (_cursorScaleChanged) {
        _cursorScaleChanged = NO;
        CGSSetCursorScale(CGSMainConnectionID(), _systemCursorScale);
    }
}

//------------------------------------------------ settings ------------------------------------------------

- (void)applyConfig:(ARConfig *)config {
    BOOL timingChanged = config.pollMillis != _config.pollMillis ||
                         config.heartbeatMillis != _config.heartbeatMillis ||
                         config.primaryDelayTicks != _config.primaryDelayTicks;
    BOOL warpChanged = config.warpMouse != _config.warpMouse;
    BOOL iconChanged = config.menuBarIcon != _config.menuBarIcon;
    _config = config;

    ARWindowFinderSetVerbose(config.verbose);
    ARFocusRingVerbose = config.verbose;
    _enabled = config.enabled;
    _focusRing.color = config.focusRingColor;
    _focusRing.style = config.focusRingStyle;
    if (!config.focusRing || !config.focusFirst || !config.enabled) { [self hideFocusRing]; }
    _delay = ARResetDelay();
    if (timingChanged) { [self startTimers]; }
    if (warpChanged) { [self registerNotifications]; }
    if (iconChanged) {
        if (config.menuBarIcon && !_menuBar) { _menuBar = [[ARMenuBar alloc] initWithDelegate: self]; }
        else if (!config.menuBarIcon) { [_menuBar remove]; _menuBar = nil; }
    }
    [_menuBar refresh];

    NSError *error = nil;
    NSString *quirksPath = ARQuirksUserFilePath();
    ARQuirks *quirks = ARQuirksLoad(quirksPath, &error);
    if (error) { NSLog(@"Ignoring %@: %@", quirksPath, error.localizedDescription); }
    else { _quirks = quirks; }
}

- (void)applySettings:(NSDictionary<NSString *, id> *)changes {
    NSError *error = nil;
    NSString *path = _config.sourcePath ?: ARConfigEnsurePath(&error);
    if (!path) {
        NSLog(@"Cannot write settings: %@", error.localizedDescription);
        return;
    }
    if (!ARConfigWrite(path, changes, &error)) {
        NSLog(@"Cannot write %@: %@", path, error.localizedDescription);
        return;
    }
    ARConfigForgetArguments(changes.allKeys);
    NSLog(@"Settings changed: %@", changes);
    BOOL isNewFile = _config.sourcePath == nil;
    [self reloadConfiguration];
    if (isNewFile) { [self watchConfigFile]; }
}

- (void)resetAllSettings {
    NSString *path = _config.sourcePath ?: ARConfigEnsurePath(nil);
    NSError *error = nil;
    if (path && ![ARConfigTemplate() writeToFile: path atomically: YES
            encoding: NSUTF8StringEncoding error: &error]) {
        NSLog(@"Cannot reset %@: %@", path, error.localizedDescription);
        return;
    }
    [self reloadConfiguration];
}

- (void)reloadConfiguration {
    ARConfig *config = ARConfigReload(_config);
    NSLog(@"Reloaded %@", config.sourcePath ?: @"defaults");
    for (NSString *warning in config.warnings) { NSLog(@"  ! %@", warning); }
    [self applyConfig: config];
}

// Editors write settings files by replacing them, so the watch is re-armed on
// every event rather than assuming the descriptor survives.
- (void)watchConfigFile {
    if (_configWatcher) {
        dispatch_source_cancel(_configWatcher);
        _configWatcher = nil;
    }
    if (!_config.liveReload) { return; }
    NSString *path = _config.sourcePath;
    if (!path) { return; }

    int descriptor = open(path.fileSystemRepresentation, O_EVTONLY);
    if (descriptor < 0) { return; }

    _configWatcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, descriptor,
        DISPATCH_VNODE_WRITE | DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME |
        DISPATCH_VNODE_EXTEND, dispatch_get_main_queue());
    __weak ARController *weakSelf = self;
    dispatch_source_set_event_handler(_configWatcher, ^{
        ARController *strongSelf = weakSelf;
        if (!strongSelf) { return; }
        // Give the editor a moment to finish writing.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
            [strongSelf reloadConfiguration];
            [strongSelf watchConfigFile];
        });
    });
    dispatch_source_set_cancel_handler(_configWatcher, ^{ close(descriptor); });
    dispatch_resume(_configWatcher);
}

//------------------------------------------------- timers -------------------------------------------------

// Nothing can ever be raised or focused when the primary delay is zero, so the
// evaluation loop is not needed at all: only warping remains.
- (BOOL)needsEvaluation {
    return _config.primaryDelayTicks > 0;
}

- (void)startTimers {
    [_fastTimer invalidate];
    _fastTimer = nil;
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;
    if (![self needsEvaluation]) { return; }

    if (_config.heartbeatMillis) {
        // The safety net for windows that appear, close or move under a mouse
        // that is not moving. Generously coalesced: it is allowed to be late.
        _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval: _config.heartbeatMillis / 1000.0
            target: self selector: @selector(heartbeat:) userInfo: nil repeats: YES];
        _heartbeatTimer.tolerance = _config.heartbeatMillis / 2000.0;
    }
}

- (void)wakeUp {
    if (![self needsEvaluation] || !_enabled) { return; }
    _idleTicks = 0;
    if (_fastTimer) { return; }
    _fastTimer = [NSTimer scheduledTimerWithTimeInterval: _config.pollMillis / 1000.0
        target: self selector: @selector(fastTick:) userInfo: nil repeats: YES];
}

- (void)fastTick:(NSTimer *)timer {
    BOOL busy = [self evaluate];
    if (busy) {
        _idleTicks = 0;
    } else if (++_idleTicks >= IDLE_TICKS_BEFORE_SLEEP) {
        // Back to sleep: the next mouse event or heartbeat wakes us again.
        [_fastTimer invalidate];
        _fastTimer = nil;
        _idleTicks = 0;
    }
}

// The safety net. The event tap can miss movement: macOS disables it after a
// timeout, and the cursor can be warped by other software without an event. A
// slow re-read costs almost nothing and keeps those cases from getting stuck.
- (void)heartbeat:(NSTimer *)timer {
    _havePoint = NO;
    if ([self evaluate]) { [self wakeUp]; }
}

- (void)startPermissionWatch {
    if (_permissionTimer) { return; }
    printf("Waiting for accessibility permission, AutoRaise starts as soon as it is granted.\n");
    _permissionTimer = [NSTimer scheduledTimerWithTimeInterval: PERMISSION_RETRY_SECONDS
        target: self selector: @selector(checkPermission:) userInfo: nil repeats: YES];
}

// Granting accessibility used to need a restart, because the event tap and the
// accessibility objects were only ever created once, at launch.
- (void)checkPermission:(NSTimer *)timer {
    if (!AXIsProcessTrusted()) { return; }
    [_permissionTimer invalidate];
    _permissionTimer = nil;
    NSLog(@"Accessibility granted");
    ARWindowFinderInit(_config.verbose);
    [self startEventTap];
    [self startTimers];
    [_menuBar refresh];
}

//----------------------------------------------- event tap ------------------------------------------------

static CGEventRef ARTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    [controller handleTappedEvent: event ofType: type];
    return event;
}

- (void)startEventTap {
    if (_eventTap) { return; }
    _eventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventFlagsChanged) |
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged),
        ARTapCallback, NULL);
    if (!_eventTap) {
        if (_config.verbose) { NSLog(@"Could not create the event tap"); }
        return;
    }
    _eventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _eventTap, 0);
    if (_eventTapSource) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), _eventTapSource, kCFRunLoopCommonModes);
        CGEventTapEnable(_eventTap, true);
    }
    if (_config.verbose) { NSLog(@"Event tap running: %s", _eventTapSource ? "YES" : "NO"); }
}

- (void)handleTappedEvent:(CGEventRef)event ofType:(CGEventType)type {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (_config.verbose) { NSLog(@"Event tap disabled, re-enabling"); }
        CGEventTapEnable(_eventTap, true);
        return;
    }

    if (type == kCGEventMouseMoved || type == kCGEventLeftMouseDragged ||
        type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged) {
        // The whole reason AutoRaise no longer polls: the mouse says when it
        // moves, so a still cursor costs nothing at all. Mouse events arrive
        // several times per frame, so this path stays as short as possible.
        _point = CGEventGetLocation(event);
        _havePoint = YES;
        if (!_fastTimer) { [self wakeUp]; }
        else { _idleTicks = 0; }
        return;
    }

    if (type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown) {
        // A click means the user has taken over: whatever they clicked is the
        // window they meant, so the ring has nothing left to say.
        [self hideFocusRing];
        return;
    }

    if (type != kCGEventKeyDown && type != kCGEventFlagsChanged) { return; }

    _flags = CGEventGetFlags(event);
    BOOL commandPressed = (_flags & TASK_SWITCHER_MODIFIER_KEY) == TASK_SWITCHER_MODIFIER_KEY;
    static BOOL commandTabPressed = NO;
    static BOOL commandGravePressed = NO;

    if (!commandPressed && commandTabPressed) {
        commandTabPressed = NO;
        _activatedByTaskSwitcher = YES;
        _ignoreTicks = 3;
    }
    if (!commandPressed && commandGravePressed) {
        commandGravePressed = NO;
        _activatedByTaskSwitcher = YES;
        _ignoreTicks = 3;
        [self onAppActivated];
    }

    if (type == kCGEventKeyDown && [self handleShortcuts: event]) { return; }

    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            commandTabPressed = commandTabPressed || commandPressed;
        } else if (_config.warpMouse && keycode == kVK_ANSI_Grave) {
            commandGravePressed = commandGravePressed || commandPressed;
        }
    }
}

static BOOL ARShortcutMatches(NSString *configured, CGEventRef event) {
    if (!configured.length) { return NO; }
    ARShortcut shortcut = ARShortcutParse(configured);
    if (!shortcut.valid) { return NO; }

    CGKeyCode keyCode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keyCode != shortcut.keyCode) { return NO; }

    CGEventFlags mask = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate |
                        kCGEventFlagMaskShift | kCGEventFlagMaskCommand;
    return (CGEventGetFlags(event) & mask) == shortcut.modifiers;
}

- (BOOL)handleShortcuts:(CGEventRef)event {
    if (ARShortcutMatches(_config.toggleShortcut, event)) {
        [self setAutoRaiseEnabled: !_enabled];
        return YES;
    }
    if (ARShortcutMatches(_config.raiseShortcut, event)) {
        [self raiseRingedWindow];
        return YES;
    }
    return NO;
}

//------------------------------------------------ focus ring ----------------------------------------------

// Raises whatever the ring is around: the window that has the keyboard but is
// still behind something.
- (void)raiseRingedWindow {
    if (!_lastFocusedWindow) {
        if (_config.verbose) { NSLog(@"Nothing focused to raise"); }
        return;
    }
    if (_config.verbose) { NSLog(@"Raise shortcut"); }
    [self raiseAndActivate: _lastFocusedWindow pid: _lastFocusedWindowPid];
    [self hideFocusRing];
}

static void ARRingObserverCallback(AXObserverRef observer, AXUIElementRef element,
                                   CFStringRef notification, void *context) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        [controller hideFocusRing];
    } else {
        [controller followRingedWindow];
    }
}

- (void)showFocusRingAround:(AXUIElementRef)window {
    if (!_config.focusRing) { return; }
    CGRect frame = CGRectZero;
    if (!ARWindowFrame(window, &frame)) { return; }

    if (_ringWindow != window) {
        [self stopFollowingRingedWindow];
        _ringWindow = (AXUIElementRef) CFRetain(window);
        AXUIElementGetPid(window, &_ringPid);
        pid_t pid = 0;
        if (AXUIElementGetPid(window, &pid) == kAXErrorSuccess &&
            AXObserverCreate(pid, ARRingObserverCallback, &_ringObserver) == kAXErrorSuccess) {
            // Following the window keeps the ring on it when it is dragged or
            // resized, without polling for the frame.
            AXObserverAddNotification(_ringObserver, window, kAXWindowMovedNotification, NULL);
            AXObserverAddNotification(_ringObserver, window, kAXWindowResizedNotification, NULL);
            AXObserverAddNotification(_ringObserver, window, kAXUIElementDestroyedNotification, NULL);
            _ringObserverSource = AXObserverGetRunLoopSource(_ringObserver);
            if (_ringObserverSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), _ringObserverSource,
                                   kCFRunLoopCommonModes);
            }
        }
    }
    [_focusRing showAroundFrame: frame ofWindow: ARWindowID(window)];
}

- (void)followRingedWindow {
    CGRect frame = CGRectZero;
    if (_ringWindow && _focusRing.visible && ARWindowFrame(_ringWindow, &frame)) {
        [_focusRing showAroundFrame: frame ofWindow: ARWindowID(_ringWindow)];
    }
}

- (void)stopFollowingRingedWindow {
    if (_ringObserver && _ringWindow) {
        for (NSString *name in @[(__bridge NSString *) kAXWindowMovedNotification,
                                 (__bridge NSString *) kAXWindowResizedNotification,
                                 (__bridge NSString *) kAXUIElementDestroyedNotification]) {
            AXObserverRemoveNotification(_ringObserver, _ringWindow, (__bridge CFStringRef) name);
        }
    }
    if (_ringObserverSource) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _ringObserverSource, kCFRunLoopCommonModes);
        _ringObserverSource = NULL;
    }
    if (_ringWindow) { CFRelease(_ringWindow); _ringWindow = NULL; }
    if (_ringObserver) { CFRelease(_ringObserver); _ringObserver = NULL; }
}

- (void)hideFocusRing {
    [_focusRing hide];
    _ringPid = 0;
    [self stopFollowingRingedWindow];
}

//---------------------------------------------- notifications ---------------------------------------------

- (void)registerNotifications {
    NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
    [center removeObserver: self];
    [center addObserver: self selector: @selector(spaceChanged:)
        name: NSWorkspaceActiveSpaceDidChangeNotification object: nil];
    [center addObserver: self selector: @selector(applicationLaunched:)
        name: NSWorkspaceDidLaunchApplicationNotification object: nil];
    // Always: the focus ring has to know when another application takes over,
    // even when the mouse warping that used to be the only reason for this
    // notification is switched off.
    [center addObserver: self selector: @selector(appActivated:)
        name: NSWorkspaceDidActivateApplicationNotification object: nil];
    [center addObserver: self selector: @selector(applicationHidden:)
        name: NSWorkspaceDidHideApplicationNotification object: nil];
    if (_config.verbose && _config.warpMouse) { NSLog(@"Registered app activated selector"); }

    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(screensChanged:)
        name: NSApplicationDidChangeScreenParametersNotification object: nil];
}

- (void)spaceChanged:(NSNotification *)notification {
    if (_config.verbose) { NSLog(@"Space changed"); }
    // The outlined window may not even be on this desktop.
    [self hideFocusRing];
    _spaceHasChanged = YES;
    _havePoint = NO;
    // Deliberately stale: the first evaluation after a space change sees a move
    // and defers, so the raise happens once the desktop has settled.
    _evaluatedPoint = CGPointZero;
    ARInvalidateDockCache();
    [self wakeUp];
}

- (void)screensChanged:(NSNotification *)notification {
    ARRefreshDesktopOrigin();
}

- (void)applicationLaunched:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if ([app.bundleIdentifier isEqualToString: @"com.apple.dock"]) { ARWindowFinderRefreshDock(); }
}

- (void)appActivated:(NSNotification *)notification {
    // Whatever just came forward holds the keyboard now, so an outline around
    // anything else is a lie. The notification names the application; asking
    // NSWorkspace here would give the previous one, because it has not caught
    // up yet, and that mistake hid every ring the moment it appeared.
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (app) { [self hideRingUnlessOwnedBy: app.processIdentifier]; }
    if (!_config.warpMouse) { return; }
    if (_config.verbose) { NSLog(@"App activated, waiting %0.3fs", ACTIVATE_DELAY_MS / 1000.0); }
    [self performSelector: @selector(onAppActivated) withObject: nil
        afterDelay: ACTIVATE_DELAY_MS / 1000.0];
}

- (void)applicationHidden:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier == _ringPid) { [self hideFocusRing]; }
}

// The ring means "this window has the keyboard", so it goes as soon as the
// keyboard belongs to some other application.
- (void)hideRingUnlessOwnedBy:(pid_t)pid {
    if (!_focusRing.visible || pid == _ringPid) { return; }
    if (_config.verbose) { NSLog(@"Keyboard went to pid %d, hiding the ring", pid); }
    [self hideFocusRing];
}

- (void)onAppActivated {
    if (![self warpMouseToActivatedWindow]) { return; }
    if (_config.cursorScale == _systemCursorScale) { return; }
    if (_config.verbose) { NSLog(@"Set cursor scale after %0.3fs", SCALE_DELAY_MS / 1000.0); }
    [self performSelector: @selector(setCursorScale:)
        withObject: @(_config.cursorScale) afterDelay: SCALE_DELAY_MS / 1000.0];
    [self performSelector: @selector(setCursorScale:)
        withObject: @(_systemCursorScale) afterDelay: SCALE_DURATION_MS / 1000.0];
}

- (void)setCursorScale:(NSNumber *)scale {
    if (_config.verbose) { NSLog(@"Set cursor scale: %@", scale); }
    _cursorScaleChanged = scale.floatValue != _systemCursorScale;
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}

- (void)windowFocused:(AXUIElementRef)window {
    NSTimeInterval delay = _config.raiseAfterFocusTicks * _config.pollMillis / 1000.0;
    if (_config.verbose) { NSLog(@"Window focused, waiting %0.3fs", delay); }
    [self performSelector: @selector(onWindowFocused:)
        withObject: @((uint64_t) (uintptr_t) window) afterDelay: delay];
}

- (void)onWindowFocused:(NSNumber *)window {
    if (window.unsignedLongLongValue == (uint64_t) _lastFocusedWindow) {
        [self raiseAndActivate: _lastFocusedWindow pid: _lastFocusedWindowPid];
    } else if (_config.verbose) {
        NSLog(@"Ignoring window focused event");
    }
}

//------------------------------------------------- raising ------------------------------------------------

- (void)activate:(pid_t)pid {
    if (_config.verbose) { NSLog(@"Activate"); }
    if (_config.legacyActivation) {
        // Needed by applications built on non native toolkits such as GTK, SDL
        // and wine, which ignore the modern activation call.
        ProcessSerialNumber process;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (GetProcessForPID(pid, &process) == noErr) {
            SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly);
        }
#pragma clang diagnostic pop
    } else {
        [[NSRunningApplication runningApplicationWithProcessIdentifier: pid] activateWithOptions: 0];
    }
}

- (void)raiseAndActivate:(AXUIElementRef)window pid:(pid_t)pid {
    if (_config.verbose) { NSLog(@"Raise"); }
    AXError error = AXUIElementPerformAction(window, kAXRaiseAction);
    if (error != kAXErrorSuccess && _config.verbose) {
        NSLog(@"Raise action refused (AXError %d), activating anyway", error);
    }
    // Activate either way: a window that will not raise should still take the
    // keyboard, otherwise hovering it appears to do nothing at all.
    [self activate: pid];
    [self hideFocusRing];
}

//---------------------------------------------- mouse warping ---------------------------------------------

- (BOOL)warpMouseToActivatedWindow {
    if (_config.verbose) { NSLog(@"App activated"); }
    if (!_config.altTaskSwitcher) {
        if (!_activatedByTaskSwitcher) { return NO; }
        _activatedByTaskSwitcher = NO;
    }
    _appWasActivated = YES;

    NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmostPid = frontmost.processIdentifier;
    AXUIElementRef _activatedWindow = ARCopyActivatedWindow(frontmostPid);

    if (_config.verbose) { NSLog(@"BundleIdentifier: %@", frontmost.bundleIdentifier); }
    BOOL finder = [frontmost.bundleIdentifier isEqualToString: @"com.apple.finder"];
    if (finder) {
        // The Finder desktop counts as a window; remember the last real one so
        // that switching to Finder warps into a folder rather than the desktop.
        if (_activatedWindow) {
            if (ARIsDesktopWindow(_activatedWindow)) {
                CFRelease(_activatedWindow);
                _activatedWindow = _previousFinderWindow ? (AXUIElementRef) CFRetain(_previousFinderWindow) : NULL;
            } else {
                if (_previousFinderWindow) { CFRelease(_previousFinderWindow); }
                _previousFinderWindow = (AXUIElementRef) CFRetain(_activatedWindow);
            }
        } else if (_previousFinderWindow) {
            _activatedWindow = (AXUIElementRef) CFRetain(_previousFinderWindow);
        }
    }

    if (_config.altTaskSwitcher) {
        CGPoint mousePoint = [self currentMousePoint];
        BOOL ignoreActivated = NO;
        AXUIElementRef _mouseWindow = ARCopyWindowAtPoint(mousePoint, _config.windowServerHitTest);
        if (_mouseWindow) {
            if (!_activatedByTaskSwitcher) {
                pid_t mouseWindowPid = 0;
                // Checking for mouse movement reduces the problem of the mouse
                // being warped when changing spaces and simultaneously moving
                // the mouse to another screen.
                ignoreActivated = fabs(mousePoint.x - _evaluatedPoint.x) > 0 ||
                                  fabs(mousePoint.y - _evaluatedPoint.y) > 0;
                // If the mouse already hovers the frontmost app, for instance
                // after only changing spaces, it should stay where it is.
                ignoreActivated = ignoreActivated ||
                    (AXUIElementGetPid(_mouseWindow, &mouseWindowPid) == kAXErrorSuccess &&
                     mouseWindowPid == frontmostPid);
            }
            CFRelease(_mouseWindow);
        } else {
            // Over the dock or the menu bar. Warping from here would surprise.
            ignoreActivated = YES;
        }
        _activatedByTaskSwitcher = NO;

        if (ignoreActivated) {
            if (_config.verbose) { NSLog(@"Ignoring app activated"); }
            if (_activatedWindow) { CFRelease(_activatedWindow); }
            return NO;
        }
    }

    if (_activatedWindow) {
        if (_config.verbose) { NSLog(@"Warp mouse"); }
        CGWarpMouseCursorPosition(ARWarpPointForWindow(_activatedWindow, _config.warpX, _config.warpY));
        CFRelease(_activatedWindow);
    }
    return YES;
}

//---------------------------------------- destroyed window tracking ---------------------------------------

static void ARObserverCallback(AXObserverRef observer, AXUIElementRef element,
                               CFStringRef notification, void *windowId) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        [controller windowDestroyed: (CGWindowID) (uintptr_t) windowId];
    }
}

- (void)windowDestroyed:(CGWindowID)windowId {
    _lastDestroyedWindowId = windowId;
}

- (void)stopObserving {
    if (_observer && _observedWindow) {
        AXObserverRemoveNotification(_observer, _observedWindow, kAXUIElementDestroyedNotification);
    }
    if (_observerSource) {
        // Without this the run loop keeps the source, the source keeps the
        // observer, and one observer leaks per window ever hovered.
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _observerSource, kCFRunLoopCommonModes);
        _observerSource = NULL;
    }
    if (_observedWindow) { CFRelease(_observedWindow); _observedWindow = NULL; }
    if (_observer) { CFRelease(_observer); _observer = NULL; }
}

- (void)observeDestructionOf:(AXUIElementRef)window pid:(pid_t)pid id:(CGWindowID)windowId {
    [self stopObserving];
    if (AXObserverCreate(pid, ARObserverCallback, &_observer) != kAXErrorSuccess || !_observer) {
        _observer = NULL;
        return;
    }
    _observedWindow = (AXUIElementRef) CFRetain(window);
    AXObserverAddNotification(_observer, window, kAXUIElementDestroyedNotification,
                              (void *) (uintptr_t) windowId);
    _observerSource = AXObserverGetRunLoopSource(_observer);
    if (_observerSource) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), _observerSource, kCFRunLoopCommonModes);
    }
}

//------------------------------------------ where it all happens ------------------------------------------

- (CGPoint)currentMousePoint {
    if (_havePoint) { return _point; }
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }
    return point;
}

- (BOOL)shouldAbortNow {
    // Never fight a drag: resizing or moving a window keeps the button down.
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight)) {
        return YES;
    }

    if (_config.disableKey) {
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
        BOOL held = (flags & _config.disableKey) == _config.disableKey;
        if (held != _config.invertDisableKey) { return YES; }
    }

    NSString *frontmostBundleId = [[NSWorkspace sharedWorkspace] frontmostApplication].bundleIdentifier;
    if (frontmostBundleId && [_config.stayFocusedBundleIds containsObject: frontmostBundleId]) {
        return YES;
    }

    // These two cost a round trip to the Dock, so they come last.
    return ARDockIsActive() || ARMissionControlIsActive();
}

// Returns YES while something is still in flight, which keeps the fast timer
// running. Returning NO lets AutoRaise go back to sleep.
- (BOOL)evaluate {
    if (!_enabled || ![self needsEvaluation]) { return NO; }

    CGPoint mousePoint = [self currentMousePoint];
    CGPoint delta = CGPointMake(mousePoint.x - _evaluatedPoint.x, mousePoint.y - _evaluatedPoint.y);
    _point = mousePoint;
    _evaluatedPoint = mousePoint;
    _havePoint = YES;

    BOOL mouseMoved = fabs(delta.x) > _config.mouseDelta || fabs(delta.y) > _config.mouseDelta;
    BOOL mouseStopped = !mouseMoved;
    mouseMoved = mouseMoved || _propagateMouseMoved;
    _propagateMouseMoved = NO;

    // delayTicks == 0 disabled, 1 elapsed, n counting down.
    if (_delay.delayTicks > 1) { _delay.delayTicks--; }

    if (@available(macOS 12.00, *)) {
        // Apply the correction before any early return below, so the corrected
        // point stays usable while the mouse rests.
        if (mouseMoved) {
            CGRect screenFrame = CGRectZero;
            CGFloat menuBarHeight = 0;
            BOOL hasScreen = ARScreenAtPoint(mousePoint, &screenFrame, &menuBarHeight);
            ARCorrectedPoint corrected = ARCorrectMousePoint(mousePoint, delta, hasScreen,
                                                             screenFrame, menuBarHeight);
            if (_config.verbose && corrected.applied) {
                NSLog(@"%@ correction", corrected.applied & ARCorrectionMenuBar ? @"Menu bar" : @"Screen edge");
            }
            mousePoint = corrected.point;
            _correctedPoint = corrected.point;
        } else {
            mousePoint = _correctedPoint;
        }
    }

    if (_ignoreTicks) {
        _ignoreTicks--;
        return YES;
    } else if (_appWasActivated) {
        _appWasActivated = NO;
        return YES;
    } else if (_spaceHasChanged) {
        // A space change takes priority over waiting for the delay.
        if (mouseMoved) { return YES; }
        if (!_config.ignoreSpaceChanged) {
            _delay.raiseTimes = AR_RAISE_REPEATS;
            _delay.delayTicks = 0;
        }
        _spaceHasChanged = NO;
    } else if (_config.requireMouseStop && !mouseStopped && mouseMoved) {
        _delay.delayTicks = 0;
        // Propagate the move so the delay restarts once the mouse settles.
        _propagateMouseMoved = YES;
        return YES;
    }

    if (!mouseMoved && !_delay.delayTicks && !_delay.raiseTimes) { return NO; }

    if ([self shouldAbortNow]) {
        if (_config.verbose) { NSLog(@"Abort focus/raise"); }
        _delay = ARResetDelay();
        return NO;
    }

    AXUIElementRef _mouseWindow = ARCopyWindowAtPoint(mousePoint, _config.windowServerHitTest);
    if (!_mouseWindow) { return mouseMoved; }

    BOOL busy = [self considerRaising: _mouseWindow];
    CFRelease(_mouseWindow);
    return busy;
}

- (BOOL)considerRaising:(AXUIElementRef)_mouseWindow {
    ARWindow *mouse = ARGatherWindow(_mouseWindow, YES);
    if (!mouse.pid) { return NO; }

    // A window whose id could not be read is not the destroyed one; treating it
    // as such would silently stop raising it.
    BOOL haveWindowId = mouse.windowId != kCGNullWindowID;
    BOOL mouseWindowPresent = !haveWindowId || mouse.windowId != _lastDestroyedWindowId;
    if (haveWindowId && mouseWindowPresent) {
        if (mouse.windowId != _previousWindowId) {
            _previousWindowId = mouse.windowId;
            _lastDestroyedWindowId = kCGNullWindowID;
            _delay = ARResetDelay();
            [self observeDestructionOf: _mouseWindow pid: mouse.pid id: mouse.windowId];
        }
    } else if (_config.verbose) {
        NSLog(@"Mouse window not present");
    }

    NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmostPid = frontmost.processIdentifier;

    ARRaiseQuery *query = [[ARRaiseQuery alloc] init];
    query.ownPid = getpid();
    query.mouseWindow = mouse;
    query.mouseWindowPresent = mouseWindowPresent;
    query.invertIgnoreApps = _config.invertIgnoreApps;
    query.focusFirst = _config.focusFirst;
    query.ignoreApps = _config.ignoreApps;
    query.ignoreTitles = _config.ignoreTitles;
    query.quirks = _quirks;

    query.focusedWindow = [[ARWindow alloc] init];
    ARRaiseDecision decision = ARDecideCandidate(query);

    AXUIElementRef _focusedWindow = NULL;
    if (decision.needsRaise) {
        _focusedWindow = ARCopyFocusedWindow(frontmostPid);
        if (_focusedWindow) {
            query.focusedWindow = ARGatherWindow(_focusedWindow, YES);
            if (_config.verbose) { ARLogWindowTitle(@"Focused window", _focusedWindow); }
        } else {
            if (_config.verbose) { NSLog(@"No focused window"); }
            query.frontmostHasMainWindow = ARApplicationHasMainWindow(frontmostPid);
        }
        decision.needsRaise = ARDecideAgainstFocused(query, decision);
    }
    if (_config.verbose && !decision.needsRaise) { NSLog(@"Nothing to raise"); }

    BOOL busy = NO;
    if (decision.needsRaise) {
        ARDelayStep step = ARAdvanceDelay(_delay, _config.primaryDelayTicks);
        _delay = step.state;
        busy = YES;
        if (step.act) {
            [self act: _mouseWindow facts: mouse focusedFacts: query.focusedWindow
                frontmost: frontmostPid decision: decision];
        }
    } else {
        _delay = ARResetDelay();
    }

    if (_focusedWindow) { CFRelease(_focusedWindow); }
    return busy;
}

- (void)act:(AXUIElementRef)_mouseWindow facts:(ARWindow *)mouse
    focusedFacts:(ARWindow *)focused frontmost:(pid_t)frontmostPid
    decision:(ARRaiseDecision)decision {
#if SKYLIGHT_AVAILABLE
    if (_config.focusFirst) {
        ProcessSerialNumber mouseWindowPsn;
        ProcessSerialNumber focusedWindowPsn;
        ProcessSerialNumber *_focusedWindowPsn = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (GetProcessForPID(mouse.pid, &mouseWindowPsn) != noErr) { return; }
        if (focused.known && GetProcessForPID(frontmostPid, &focusedWindowPsn) == noErr) {
            _focusedWindowPsn = &focusedWindowPsn;
        }
#pragma clang diagnostic pop

        if (mouse.isFloating) {
            // The private call cannot focus a floating window without raising
            // it, and leaving it alone would make hovering one do nothing.
            if (_config.verbose) { NSLog(@"Floating window, raising instead of focusing"); }
            [self raiseAndActivate: _mouseWindow pid: mouse.pid];
            return;
        }
        if (!decision.appRaisesOnFocus || _config.raiseAfterFocusTicks == 0) {
            window_manager_focus_window_without_raise(&mouseWindowPsn, mouse.windowId,
                _focusedWindowPsn, focused.windowId, _config.verbose);
        }

        if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
        _lastFocusedWindow = (AXUIElementRef) CFRetain(_mouseWindow);
        _lastFocusedWindowPid = mouse.pid;
        [self showFocusRingAround: _mouseWindow];
        if (_config.raiseAfterFocusTicks) { [self windowFocused: _lastFocusedWindow]; }
        return;
    }
#endif
    [self raiseAndActivate: _mouseWindow pid: mouse.pid];
}

//--------------------------------------------- menu bar glue ----------------------------------------------

- (BOOL)autoRaiseEnabled { return _enabled; }

- (void)setAutoRaiseEnabled:(BOOL)enabled {
    _enabled = enabled;
    _delay = ARResetDelay();
    if (!enabled) { [self hideFocusRing]; }
    if (enabled) { [self wakeUp]; } else { [_fastTimer invalidate]; _fastTimer = nil; }
    NSLog(@"AutoRaise %@", enabled ? @"enabled" : @"disabled");
    [self applySettings: @{@"enabled": enabled ? @"true" : @"false"}];
    [_menuBar refresh];
}

- (BOOL)accessibilityGranted { return AXIsProcessTrusted(); }

- (void)requestAccessibility {
    // Asking again brings up the pane with AutoRaise already listed.
    NSDictionary *options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
    [[NSWorkspace sharedWorkspace] openURL: [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
}

- (ARConfig *)currentConfig { return _config; }

- (NSString *)settingsFilePath { return _config.sourcePath; }

- (BOOL)loginItemAvailable {
    if (@available(macOS 13.0, *)) {
        // Registering only means anything for a real bundle.
        return NSBundle.mainBundle.bundleIdentifier != nil;
    }
    return NO;
}

- (BOOL)loginItemEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)setLoginItemEnabled:(BOOL)enabled {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = enabled ? [SMAppService.mainAppService registerAndReturnError: &error]
                          : [SMAppService.mainAppService unregisterAndReturnError: &error];
        if (ok) { return; }
        NSLog(@"Could not change the login item: %@", error.localizedDescription);
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Could not change the login item";
        alert.informativeText = error.localizedDescription ?:
            @"Move AutoRaise to the Applications folder and try again.";
        [alert runModal];
    }
}

- (void)openSettings {
    // A settings window of our own means AutoRaise holds the keyboard.
    [self hideFocusRing];
    if (!_settingsWindow) {
        _settingsWindow = [[ARSettingsWindowController alloc] initWithDelegate: self];
    } else {
        [_settingsWindow rebuild];
    }
    // A window deserves a dock icon and a menu bar while it is open, so that
    // copy and paste in the text fields behave the way people expect.
    [NSApp setActivationPolicy: NSApplicationActivationPolicyRegular];
    [_settingsWindow show];
}

- (NSString *)diagnosticsReport {
    NSProcessInfo *process = [NSProcessInfo processInfo];
    NSMutableString *report = [NSMutableString string];
    [report appendFormat: @"AutoRaise %s\n", AUTORAISE_VERSION];
    [report appendFormat: @"macOS %@\n", process.operatingSystemVersionString];
    [report appendFormat: @"Accessibility: %@\n", AXIsProcessTrusted() ? @"granted" : @"not granted"];
    [report appendFormat: @"SkyLight: %@\n",
        ARWindowServerHitTestAvailable() ? @"available" : @"missing"];
    [report appendFormat: @"Hit test: %@\n",
        _config.windowServerHitTest ? @"window server" : @"accessibility"];
    [report appendFormat: @"Delay: %d ticks, focus delay: %d ticks, poll %dms\n",
        _config.delayTicks, _config.focusDelayTicks, _config.pollMillis];
    [report appendFormat: @"Focus first: %@\n", _config.focusFirst ? @"yes" : @"no"];
    [report appendFormat: @"Settings: %@\n", _config.sourcePath ?: @"defaults only"];
    [report appendFormat: @"Quirks: %@\n", ARQuirksUserFilePath() ?: @"built in only"];
    [report appendFormat: @"Bundle: %@\n", NSBundle.mainBundle.bundleIdentifier ?: @"command line"];
    for (NSString *warning in _config.warnings) { [report appendFormat: @"Warning: %@\n", warning]; }
    return report;
}

- (NSString *)statusSummary {
    if (!AXIsProcessTrusted()) { return @"Accessibility access needed"; }
    if (!_enabled) { return @"Paused"; }
    if (!_config.primaryDelayTicks) { return @"Warping only"; }
    int millis = (_config.primaryDelayTicks - 1) * _config.pollMillis;
    NSString *action = _config.focusFirst ? @"Focusing" : @"Raising";
    if (!millis) { return [NSString stringWithFormat: @"%@ immediately", action]; }
    return [NSString stringWithFormat: @"%@ after %dms", action, millis];
}

@end

//--------------------------------------------------- main -------------------------------------------------

static void ARCleanUp(void) { [controller shutDown]; }

// Signals arrive through the run loop rather than a handler, so the cursor scale
// is restored with ordinary code instead of async-signal-safe code.
static NSMutableArray *signalSources = nil;

static void ARWatchSignals(void) {
    signalSources = [NSMutableArray array];
    for (NSNumber *number in @[@SIGINT, @SIGTERM, @SIGHUP]) {
        int signalNumber = number.intValue;
        signal(signalNumber, SIG_IGN);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
            signalNumber, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(source, ^{
            [controller shutDown];
            exit(0);
        });
        dispatch_resume(source);
        [signalSources addObject: source];   // a released source stops firing
    }
}

// Prints what each hit test route sees at the current mouse position. Useful
// when a window will not raise: it separates "AutoRaise cannot find the window"
// from "AutoRaise decided not to".
static void ARProbe(void) {
    ARWindowFinderInit(YES);
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    CGRect screenFrame = CGRectZero;
    CGFloat menuBarHeight = 0;
    BOOL hasScreen = ARScreenAtPoint(point, &screenFrame, &menuBarHeight);
    printf("\nMouse at (%.0f, %.0f)\n", point.x, point.y);
    if (hasScreen) {
        printf("Display (%.0f, %.0f) %.0fx%.0f, menu bar %.0f\n", screenFrame.origin.x,
            screenFrame.origin.y, screenFrame.size.width, screenFrame.size.height, menuBarHeight);
    } else {
        printf("No display holds that point\n");
    }

    ARQuirks *quirks = ARQuirksLoad(ARQuirksUserFilePath(), nil);
    for (int useWindowServer = 1; useWindowServer >= 0; useWindowServer--) {
        printf("\n%s hit test:\n", useWindowServer ? "Window server" : "Accessibility");
        AXUIElementRef _window = ARCopyWindowAtPoint(point, useWindowServer);
        if (!_window) { printf("  no raisable window\n"); continue; }
        ARWindow *facts = ARGatherWindow(_window, YES);
        printf("  window %u of %s (pid %d, %s)\n", facts.windowId,
            facts.appName ? facts.appName.UTF8String : "?", facts.pid,
            facts.bundleId ? facts.bundleId.UTF8String : "?");
        printf("  title: %s\n", facts.title ? facts.title.UTF8String : "(none)");
        printf("  frame: (%.0f, %.0f) %.0fx%.0f\n", facts.frame.origin.x, facts.frame.origin.y,
            facts.frame.size.width, facts.frame.size.height);
        printf("  main: %s, dialog: %s, floating: %s, full screen: %s\n",
            facts.isMain ? "yes" : "no", facts.isDialog ? "yes" : "no",
            facts.isFloating ? "yes" : "no", ARIsFullScreen(facts) ? "yes" : "no");
        printf("  counts as a main window: %s\n", ARIsMainWindow(facts, quirks) ? "yes" : "no");
        CFRelease(_window);
    }
    printf("\n");
}

static NSMenu *ARBuildMainMenu(void) {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle: @"About AutoRaise" action: @selector(orderFrontStandardAboutPanel:)
        keyEquivalent: @""];
    [appMenu addItem: [NSMenuItem separatorItem]];
    [appMenu addItemWithTitle: @"Settings…" action: @selector(openSettings) keyEquivalent: @","];
    [appMenu addItem: [NSMenuItem separatorItem]];
    [appMenu addItemWithTitle: @"Hide AutoRaise" action: @selector(hide:) keyEquivalent: @"h"];
    [appMenu addItemWithTitle: @"Quit AutoRaise" action: @selector(terminate:) keyEquivalent: @"q"];
    appItem.submenu = appMenu;
    [mainMenu addItem: appItem];

    NSMenuItem *editItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle: @"Edit"];
    [editMenu addItemWithTitle: @"Undo" action: @selector(undo:) keyEquivalent: @"z"];
    [[editMenu addItemWithTitle: @"Redo" action: @selector(redo:) keyEquivalent: @"z"]
        setKeyEquivalentModifierMask: NSEventModifierFlagCommand | NSEventModifierFlagShift];
    [editMenu addItem: [NSMenuItem separatorItem]];
    [editMenu addItemWithTitle: @"Cut" action: @selector(cut:) keyEquivalent: @"x"];
    [editMenu addItemWithTitle: @"Copy" action: @selector(copy:) keyEquivalent: @"c"];
    [editMenu addItemWithTitle: @"Paste" action: @selector(paste:) keyEquivalent: @"v"];
    [editMenu addItemWithTitle: @"Select All" action: @selector(selectAll:) keyEquivalent: @"a"];
    editItem.submenu = editMenu;
    [mainMenu addItem: editItem];

    NSMenuItem *windowItem = [[NSMenuItem alloc] init];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle: @"Window"];
    [windowMenu addItemWithTitle: @"Close" action: @selector(performClose:) keyEquivalent: @"w"];
    [windowMenu addItemWithTitle: @"Minimize" action: @selector(performMiniaturize:)
        keyEquivalent: @"m"];
    windowItem.submenu = windowMenu;
    [mainMenu addItem: windowItem];

    return mainMenu;
}

@interface ARAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ARAppDelegate
- (void)applicationWillTerminate:(NSNotification *)notification { [controller shutDown]; }

// Reopening from the dock, while a settings window has put us there.
- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)visible {
    if (!visible) { [controller openSettings]; }
    return YES;
}

- (void)openSettings { [controller openSettings]; }
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String: argv[i]];
            if ([argument isEqualToString: @"-help"] || [argument isEqualToString: @"--help"] ||
                [argument isEqualToString: @"-h"]) {
                printf("AutoRaise %s by sbmpost(c) 2026\n\n%s", AUTORAISE_VERSION, ARConfigUsage().UTF8String);
                return 0;
            }
            if ([argument isEqualToString: @"-version"] || [argument isEqualToString: @"--version"]) {
                printf("%s\n", AUTORAISE_VERSION);
                return 0;
            }
            if ([argument isEqualToString: @"-dumpQuirks"] || [argument isEqualToString: @"--dumpQuirks"]) {
                printf("%s\n", ARQuirksJSON(ARQuirksDefaults()).UTF8String);
                return 0;
            }
            if ([argument isEqualToString: @"-probe"] || [argument isEqualToString: @"--probe"]) {
                ARProbe();
                return 0;
            }
        }

        ARConfig *config = ARConfigLoad(argc, argv);
        printf("\nAutoRaise %s by sbmpost(c) 2026, -help for usage\n\n", AUTORAISE_VERSION);
        printf("%s\n", ARConfigSummary(config).UTF8String);
#if !SKYLIGHT_AVAILABLE
        if (config.focusDelayTicks) {
            printf("! focusDelay needs the SkyLight framework, which is missing: ignoring it\n\n");
            config.focusDelayTicks = 0;
            if (!config.delayTicks) { config.delayTicks = 1; }
        }
#endif

        // Ask for permission on the first run; the app keeps waiting until it is
        // granted rather than needing a restart.
        NSDictionary *options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        BOOL trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (config.verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        NSApplication *app = [NSApplication sharedApplication];
        // A menu bar item without a dock icon, also when run from a terminal.
        [app setActivationPolicy: NSApplicationActivationPolicyAccessory];
        ARAppDelegate *delegate = [[ARAppDelegate alloc] init];
        app.delegate = delegate;
        app.mainMenu = ARBuildMainMenu();

        ARController *instance = [[ARController alloc] initWithConfig: config];
        (void) instance;
        atexit(ARCleanUp);
        ARWatchSignals();

        [app run];
    }
    return 0;
}
