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

#import "AppTable.h"
#import "Config.h"
#import "FocusRing.h"
#import "Inspector.h"
#import "MenuBar.h"
#import "Policy.h"
#import "Quirks.h"
#import "Stats.h"
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
// How often to look while the pointer is moving, and the idle safety net. These
// used to be settings, which made people tune an implementation detail.
#define EVALUATE_MILLIS 20
#define HEARTBEAT_MILLIS 500
// How long after a hotkey an application coming forward still counts as a
// deliberate switch rather than something the application did by itself.
#define AR_SWITCHER_GRACE 1.0

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
    ProcessSerialNumber *_focused_window_psn, uint32_t focused_window_id,
    BOOL makeKeyWindow, BOOL verbose
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
    // These are what tell the application which of its windows takes the
    // keyboard, and they are also what an application that raises itself reacts
    // to. Leaving them out keeps such an application where it is, at the price
    // of letting it choose the window.
    if (makeKeyWindow) { window_manager_make_key_window(_window_psn, window_id); }
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
    NSTimeInterval _lastKeystroke;      // typing is intent too, of a different kind
    NSTimeInterval _lastHotkey;         // a modified keystroke: maybe a task switcher
    ARInspector *_inspector;            // nil until somebody asks to watch
    AXUIElementRef _previousWindow;     // where the keyboard was before this
    pid_t _previousWindowPid;

    // How the pointer is moving, which is what decides when to act.
    ARIntentReader *_intent;
    BOOL _arrived;              // latched: arrival is announced on one sample only
    BOOL _wasTravelling;        // for saying so once rather than every evaluation

    // Repeat bookkeeping, see Policy.h.
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
    NSTimer *_statsTimer;
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
        _intent = [[ARIntentReader alloc] initWithTuning: config.tuning];
        _delay = ARResetDelay();
        _previousWindowId = kCGNullWindowID;
        _lastDestroyedWindowId = kCGNullWindowID;
        controller = self;

        [self adoptOldListsFrom: config];

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
    [[ARStats shared] flush: YES];
    [self rememberPreviousWindow: NULL pid: 0];
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

// Settings files people already have carry the lists this version replaced.
// They become rows on the first launch that finds no table; the lists still
// work either way, so nothing depends on this having happened.
- (void)adoptOldListsFrom:(ARConfig *)config {
    ARAppTable *apps = [ARAppTable shared];
    if (apps.rules.count) { return; }

    [apps adoptLists: config.ignoreApps
            inverted: config.invertIgnoreApps
           keepFocus: config.stayFocusedBundleIds];
    if (apps.rules.count) {
        printf("Moved %lu application(s) from your lists into %s\n",
               (unsigned long) apps.rules.count, [ARAppTable path].UTF8String);
    }
}

- (void)applyConfig:(ARConfig *)config {
    BOOL timingChanged = config.mode != _config.mode;
    BOOL warpChanged = config.warpMouse != _config.warpMouse;
    BOOL iconChanged = config.menuBarIcon != _config.menuBarIcon;
    _config = config;

    ARWindowFinderSetVerbose(config.verbose);
    ARFocusRingVerbose = config.verbose;
    _enabled = config.enabled;
    _intent.tuning = config.tuning;
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
    // Warping only: nothing is ever raised or focused, so there is nothing to
    // work out on each movement.
    return _config.raises || _config.focusFirst;
}

- (void)startTimers {
    [_fastTimer invalidate];
    _fastTimer = nil;
    [_heartbeatTimer invalidate];
    _heartbeatTimer = nil;

    // The figures are written from here rather than as they are counted, and
    // they are worth writing even when nothing is being raised: warping counts.
    if (!_statsTimer) {
        _statsTimer = [NSTimer scheduledTimerWithTimeInterval: 60 target: self
            selector: @selector(flushStats:) userInfo: nil repeats: YES];
        _statsTimer.tolerance = 30;
    }

    if (![self needsEvaluation]) { return; }

    // The safety net for a pointer that stopped without the tap saying so, and
    // for windows that move under it. Generously coalesced: it may be late.
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval: HEARTBEAT_MILLIS / 1000.0
        target: self selector: @selector(heartbeat:) userInfo: nil repeats: YES];
    _heartbeatTimer.tolerance = HEARTBEAT_MILLIS / 2000.0;
}

- (void)wakeUp {
    if (![self needsEvaluation] || !_enabled) { return; }
    _idleTicks = 0;
    if (_fastTimer) { return; }
    _fastTimer = [NSTimer scheduledTimerWithTimeInterval: EVALUATE_MILLIS / 1000.0
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
    // No events since the last one means the pointer is parked, whatever the
    // last speed reading was.
    if ([_intent settleAtTime: [NSDate timeIntervalSinceReferenceDate]].arrived) {
        _arrived = YES;
    }
    if ([self evaluate]) { [self wakeUp]; }
}

- (void)flushStats:(NSTimer *)timer { [[ARStats shared] flush: NO]; }

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
        ARIntent intent = [_intent addPoint: _point
            atTime: [NSDate timeIntervalSinceReferenceDate]];
        if (intent.arrived) { _arrived = YES; }
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

    if (type == kCGEventKeyDown) { _lastKeystroke = [NSDate timeIntervalSinceReferenceDate]; }
    _flags = CGEventGetFlags(event);

    // A third party task switcher is a hotkey followed by an application coming
    // forward. Noting when a modified keystroke happened is enough to tell that
    // pair apart from an application activating on its own, which is why there
    // is no longer a setting saying which switcher you use.
    if (_flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl)) {
        _lastHotkey = [NSDate timeIntervalSinceReferenceDate];
    }
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
    if (ARShortcutMatches(_config.returnShortcut, event)) {
        [self returnToPreviousWindow];
        return YES;
    }
    return NO;
}

// Following the pointer costs you the idea of where you just were. This gives it
// back: the window the keyboard was on before the current one.
- (void)returnToPreviousWindow {
    if (!_previousWindow) {
        if (_config.verbose) { NSLog(@"No previous window to go back to"); }
        return;
    }
    if (_config.verbose) { NSLog(@"Back to the previous window"); }
    AXUIElementRef going = (AXUIElementRef) CFRetain(_previousWindow);
    pid_t goingPid = _previousWindowPid;
    // Swap, so the shortcut toggles between two windows.
    [self rememberPreviousWindow: _lastFocusedWindow pid: _lastFocusedWindowPid];
    [self raiseAndActivate: going pid: goingPid];
    [[ARStats shared] recordShortcutRaise];
    CFRelease(going);
}

- (void)rememberPreviousWindow:(AXUIElementRef)window pid:(pid_t)pid {
    if (_previousWindow) { CFRelease(_previousWindow); _previousWindow = NULL; }
    if (window) { _previousWindow = (AXUIElementRef) CFRetain(window); }
    _previousWindowPid = pid;
}

// A window that was not on top before, and is on top a moment later, brought
// itself forward: nothing here asked for that.
- (void)checkWhetherItRaisedItself:(ARWindow *)window wasOnTop:(CGWindowID)wasOnTop {
    ARWindow *snapshot = window;
    CGWindowID expected = wasOnTop;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (ARTopmostWindowId() != snapshot.windowId) { return; }
        if (expected == snapshot.windowId) { return; }
        if ([[ARAppTable shared] noteRaisesItself: snapshot]) {
            NSLog(@"%@ brings itself to the front when focused; it will be focused quietly "
                   "from now on", snapshot.appName ?: snapshot.bundleId);
        }
    });
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
    [[ARStats shared] recordShortcutRaise];
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
    [_intent reset];
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
    NSTimeInterval delay = _config.raiseAfterMillis / 1000.0;
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
    if (_config.legacyActivation || [self knownToNeedLegacyActivation: pid]) {
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

- (void)noteFocusMovedTo:(AXUIElementRef)window pid:(pid_t)pid {
    if (_lastFocusedWindow && _lastFocusedWindowPid != pid) {
        [self rememberPreviousWindow: _lastFocusedWindow pid: _lastFocusedWindowPid];
    }
}

- (BOOL)knownToNeedLegacyActivation:(pid_t)pid {
    ARWindow *facts = [[ARWindow alloc] init];
    facts.pid = pid;
    facts.bundleId = [NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        .bundleIdentifier;
    facts.appName = [NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        .localizedName;
    return [[ARAppTable shared] traitsFor: facts].needsLegacyActivation;
}

// The modern call is ignored by applications built on some other toolkit. Rather
// than a setting nobody can be expected to know about, notice it and remember.
- (void)checkWhetherActivationTook:(ARWindow *)window {
    ARWindow *snapshot = window;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        pid_t frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication].processIdentifier;
        if (frontmost == snapshot.pid) { return; }
        if ([[ARAppTable shared] noteNeedsLegacyActivation: snapshot]) {
            NSLog(@"%@ ignored being activated; the older call will be used for it from now on",
                  snapshot.appName ?: snapshot.bundleId);
        }
    });
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
    // Only a switch somebody asked for moves the pointer. Command-tab is
    // recognized outright; any other switcher shows up as a hotkey an instant
    // before the application arrives. An application activating by itself, a
    // notification or a file opening, moves nothing.
    NSTimeInterval sinceHotkey = [NSDate timeIntervalSinceReferenceDate] - _lastHotkey;
    BOOL byHotkey = _lastHotkey > 0 && sinceHotkey < AR_SWITCHER_GRACE;
    if (!_activatedByTaskSwitcher && !byHotkey) {
        if (_config.verbose) { NSLog(@"Activated without a switch, not warping"); }
        return NO;
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

    {
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
        _lastHotkey = 0;

        if (ignoreActivated) {
            if (_config.verbose) { NSLog(@"Ignoring app activated"); }
            if (_activatedWindow) { CFRelease(_activatedWindow); }
            return NO;
        }
    }

    if (_activatedWindow) {
        if (_config.verbose) { NSLog(@"Warp mouse"); }
        CGPoint from = [self currentMousePoint];
        CGPoint to = ARWarpPointForWindow(_activatedWindow, _config.warpX, _config.warpY);
        CGWarpMouseCursorPosition(to);
        [[ARStats shared] recordWarpOver: hypot(to.x - from.x, to.y - from.y)];
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

//-------------------------------------------- the inspector -----------------------------------------------

- (BOOL)inspectorVisible { return _inspector.visible; }

- (void)toggleInspector {
    if (!_inspector) { _inspector = [[ARInspector alloc] init]; }
    [_inspector toggle];
    if (!_inspector.visible) { return; }

    // Say something the moment it opens rather than sitting blank until the
    // pointer moves, and if the reason nothing happens is permission, say that.
    if (![self accessibilityGranted]) {
        [self explain: @"Nothing can happen yet"
              because: @"AutoRaise has no accessibility permission, so it cannot see windows"];
    } else {
        [self explain: @"Nothing yet" because: @"Move the pointer over a window"];
    }
}

// A one line state, for the ways out that never reach a decision.
- (void)explain:(NSString *)summary because:(NSString *)reason {
    if (!_inspector.visible) { return; }
    [_inspector updateWithWindow: nil app: nil summary: summary
                           trace: reason.length ? @[reason] : @[]
                           facts: [self inspectorFacts]];
}

// The settings that shaped the decision, so the panel answers "why" without
// having to be read next to the settings window.
- (NSArray<NSString *> *)inspectorFacts {
    NSMutableArray<NSString *> *facts = [NSMutableArray array];
    [facts addObject: [NSString stringWithFormat: @"On hover: %@ · eagerness: %@",
                       ARHoverModeDescribe(_config.mode),
                       AREagernessDescribe(_config.eagerness)]];
    if (!_enabled) { [facts addObject: @"AutoRaise is paused"]; }
    return facts;
}

- (CGPoint)currentMousePoint {
    if (_havePoint) { return _point; }
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint point = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }
    return point;
}

// Nil when there is nothing in the way. The words are for the inspector, so a
// hover that does nothing can say why without a terminal.
- (NSString *)abortReason {
    // Never fight a drag: resizing or moving a window keeps the button down.
    if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight)) {
        return @"A mouse button is down, which is a drag rather than a hover";
    }

    if (_config.disableKey) {
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
        BOOL held = (flags & _config.disableKey) == _config.disableKey;
        if (held != _config.invertDisableKey) {
            return held ? [NSString stringWithFormat: @"The %@ key is held down",
                                                      _config.disableKeyName]
                        : [NSString stringWithFormat: @"The %@ key is not held down",
                                                      _config.disableKeyName];
        }
    }

    // An application that must not lose the keyboard stops the whole evaluation,
    // before anything costs an accessibility call.
    NSRunningApplication *frontmost = [[NSWorkspace sharedWorkspace] frontmostApplication];
    NSString *frontmostBundleId = frontmost.bundleIdentifier;
    if (frontmostBundleId && [_config.stayFocusedBundleIds containsObject: frontmostBundleId]) {
        return @"The application in front is on the list that keeps the keyboard";
    }
    ARWindow *front = [[ARWindow alloc] init];
    front.bundleId = frontmostBundleId;
    front.appName = frontmost.localizedName;
    if ([[ARAppTable shared] policyFor: front] == ARAppPolicyKeepFocus) {
        return [NSString stringWithFormat: @"%@ is in front and its rule says it never loses "
                                            "the keyboard", frontmost.localizedName ?: @"It"];
    }

    // These two cost a round trip to the Dock, so they come last.
    if (ARDockIsActive()) { return @"The Dock has the keyboard"; }
    if (ARMissionControlIsActive()) { return @"Mission Control is open"; }
    return nil;
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

    BOOL mouseMoved = fabs(delta.x) > 0 || fabs(delta.y) > 0;
    ARIntent intent = _intent.intent;
    if (_config.verbose && intent.settled == _wasTravelling) {
        NSLog(@"%@ (%.0f pt/s)", intent.settled ? @"Pointer arrived" : @"Pointer travelling",
              intent.speed);
    }
    _wasTravelling = !intent.settled;
    // Arrival is announced once; the tap latched it, this consumes it.
    BOOL arrived = _arrived;
    _arrived = NO;

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
        // A desktop change takes priority: the pointer may not have moved at
        // all and yet be over something new.
        if (intent.settled) {
            if (!_config.ignoreSpaceChanged) {
                _delay.raiseTimes = AR_RAISE_REPEATS;
                arrived = YES;
            }
            _spaceHasChanged = NO;
        } else {
            return YES;
        }
    }

    // Typing is a claim on the keyboard. Taking it away mid-sentence loses the
    // next few characters, so a hover waits until the typing pauses.
    if (_config.typingGraceMillis > 0 && _lastKeystroke > 0) {
        NSTimeInterval since = [NSDate timeIntervalSinceReferenceDate] - _lastKeystroke;
        if (since < _config.typingGraceMillis / 1000.0) {
            if (_config.verbose && arrived) {
                NSLog(@"Still typing (%.0fms ago), leaving the keyboard alone", since * 1000);
            }
            [self explain: @"Waiting" because: [NSString stringWithFormat:
                @"You typed %.0fms ago, and taking the keyboard mid-sentence loses characters",
                since * 1000]];
            return YES;
        }
    }

    // Still travelling: whatever is under the pointer on the way is not what
    // was being aimed at.
    if (!intent.settled) {
        [self explain: @"Waiting" because: [NSString stringWithFormat:
            @"The pointer is still travelling, at %.0f pt/s", intent.speed]];
        _delay = ARResetDelay();
        return YES;
    }
    if (!arrived && !_delay.raiseTimes) { return NO; }

    NSString *abort = [self abortReason];
    if (abort) {
        if (_config.verbose) { NSLog(@"Abort focus/raise: %@", abort); }
        [self explain: @"On hold" because: abort];
        _delay = ARResetDelay();
        return NO;
    }

    AXUIElementRef _mouseWindow = ARCopyWindowAtPoint(mousePoint, _config.windowServerHitTest);
    if (!_mouseWindow) {
        [self explain: @"Nothing to do" because: @"No window under the pointer: the desktop, "
                                                 "the Dock or the menu bar"];
        return mouseMoved;
    }

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

    ARAppTable *apps = [ARAppTable shared];
    ARRaiseQuery *query = [[ARRaiseQuery alloc] init];
    query.ownPid = getpid();
    query.mouseWindow = mouse;
    query.hoveredPolicy = [apps policyFor: mouse];
    query.mouseWindowPresent = mouseWindowPresent;
    query.focusFirst = _config.focusFirst;
    query.ignoreApps = _config.ignoreApps;
    query.ignoreTitles = _config.ignoreTitles;
    query.quirks = _quirks;

    if (_inspector.visible) { query.trace = [NSMutableArray array]; }

    query.focusedWindow = [[ARWindow alloc] init];
    ARRaiseDecision decision = ARDecideCandidate(query);

    AXUIElementRef _focusedWindow = NULL;
    if (decision.needsRaise) {
        _focusedWindow = ARCopyFocusedWindow(frontmostPid);
        if (_focusedWindow) {
            query.focusedWindow = ARGatherWindow(_focusedWindow, YES);
            query.focusedPolicy = [apps policyFor: query.focusedWindow];
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
        ARDelayStep step = ARAdvanceDelay(_delay, 1);
        _delay = step.state;
        busy = YES;
        if (step.act) {
            ARSavedAction action = [self act: _mouseWindow facts: mouse
                focusedFacts: query.focusedWindow frontmost: frontmostPid decision: decision];
            // The same hover is acted on a few times over, to convince apps that
            // ignore the first attempt. Only the first one is a click saved.
            if (_delay.raiseTimes == AR_RAISE_REPEATS) {
                [[ARStats shared] recordAction: action app: mouse.appName
                                      bundleId: mouse.bundleId];
            }
        }
    } else {
        _delay = ARResetDelay();
    }

    if (query.trace) { [self publish: query decision: decision acted: busy]; }
    if (_focusedWindow) { CFRelease(_focusedWindow); }
    return busy;
}

- (void)publish:(ARRaiseQuery *)query decision:(ARRaiseDecision)decision acted:(BOOL)acted {
    ARWindow *mouse = query.mouseWindow;
    NSMutableArray<NSString *> *facts = [[self inspectorFacts] mutableCopy];
    if (query.hoveredPolicy != ARAppPolicyDefault) {
        [facts addObject: [NSString stringWithFormat: @"Its rule in apps.json: %@",
                           ARAppPolicyDescribe(query.hoveredPolicy)]];
    }
    ARAppTraits traits = [[ARAppTable shared] traitsFor: mouse];
    if (traits.raisesItself) { [facts addObject: @"Learned: it raises itself when focused"]; }
    if (traits.needsLegacyActivation) {
        [facts addObject: @"Learned: it needs the old way of activating"];
    }
    if (query.focusedWindow.known && query.focusedWindow.windowId != mouse.windowId) {
        [facts addObject: [NSString stringWithFormat: @"The keyboard is on %@",
                           query.focusedWindow.appName ?: @"another window"]];
    }

    NSString *app = mouse.appName ?: @"";
    if (mouse.bundleId.length) {
        app = [NSString stringWithFormat: @"%@ · %@", app, mouse.bundleId];
    }
    [_inspector updateWithWindow: mouse.title.length ? mouse.title : @"An untitled window"
                            app: app
                        summary: ARDecisionSummary(query, decision, _config.focusFirst)
                          trace: query.trace
                          facts: facts];
}

//------------------------------------------ where it all happens ------------------------------------------

- (ARSavedAction)act:(AXUIElementRef)_mouseWindow facts:(ARWindow *)mouse
    focusedFacts:(ARWindow *)focused frontmost:(pid_t)frontmostPid
    decision:(ARRaiseDecision)decision {
    ARAppPolicy policy = [[ARAppTable shared] policyFor: mouse];
    BOOL focusFirst = _config.focusFirst;
    if (policy == ARAppPolicyRaise) { focusFirst = NO; }
    if (policy == ARAppPolicyFocus || policy == ARAppPolicyQuiet) { focusFirst = YES; }
#if SKYLIGHT_AVAILABLE
    if (focusFirst) {
        ProcessSerialNumber mouseWindowPsn;
        ProcessSerialNumber focusedWindowPsn;
        ProcessSerialNumber *_focusedWindowPsn = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if (GetProcessForPID(mouse.pid, &mouseWindowPsn) != noErr) { return ARSavedActionNone; }
        if (focused.known && GetProcessForPID(frontmostPid, &focusedWindowPsn) == noErr) {
            _focusedWindowPsn = &focusedWindowPsn;
        }
#pragma clang diagnostic pop

        if (mouse.isFloating) {
            // The private call cannot focus a floating window without raising
            // it, and leaving it alone would make hovering one do nothing.
            if (_config.verbose) { NSLog(@"Floating window, raising instead of focusing"); }
            [self raiseAndActivate: _mouseWindow pid: mouse.pid];
            return ARSavedActionRaised;
        }
        // Applications that bring themselves to the front when focused get one
        // of three treatments, see selfRaisingApps.
        BOOL makeKeyWindow = YES;
        BOOL raisesItself = decision.appRaisesOnFocus ||
                            [[ARAppTable shared] traitsFor: mouse].raisesItself;
        if (raisesItself) {
            switch (_config.selfRaisingApps) {
                case ARSelfRaisingSkip:
                    if (_config.verbose) {
                        NSLog(@"%@ raises itself when focused, leaving it alone", mouse.appName);
                    }
                    return ARSavedActionNone;
                case ARSelfRaisingQuiet:
                    makeKeyWindow = NO;
                    if (_config.verbose) {
                        NSLog(@"%@ raises itself when focused, focusing it quietly",
                              mouse.appName);
                    }
                    break;
                default:
                    break;
            }
        }
        // Watch what it does with the focus: an application that comes forward
        // by itself is worth remembering, so it can be focused quietly next
        // time instead of surprising anybody twice.
        CGWindowID wasOnTop = makeKeyWindow ? ARTopmostWindowId() : kCGNullWindowID;
        window_manager_focus_window_without_raise(&mouseWindowPsn, mouse.windowId,
            _focusedWindowPsn, focused.windowId, makeKeyWindow, _config.verbose);
        if (makeKeyWindow && wasOnTop != kCGNullWindowID && wasOnTop != mouse.windowId) {
            [self checkWhetherItRaisedItself: mouse wasOnTop: wasOnTop];
        }

        [self noteFocusMovedTo: _mouseWindow pid: mouse.pid];
        if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
        _lastFocusedWindow = (AXUIElementRef) CFRetain(_mouseWindow);
        _lastFocusedWindowPid = mouse.pid;
        [self showFocusRingAround: _mouseWindow];
        if (_config.mode == ARHoverModeFocusThenRaise) {
            [self windowFocused: _lastFocusedWindow];
        }
        return ARSavedActionFocused;
    }
#endif
    [self noteFocusMovedTo: _mouseWindow pid: mouse.pid];
    if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
    _lastFocusedWindow = (AXUIElementRef) CFRetain(_mouseWindow);
    _lastFocusedWindowPid = mouse.pid;
    [self raiseAndActivate: _mouseWindow pid: mouse.pid];
    if (!_config.legacyActivation) { [self checkWhetherActivationTook: mouse]; }
    return ARSavedActionRaised;
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
    [report appendFormat: @"On hover: %@, eagerness %@, raise after %dms\n",
        ARHoverModeDescribe(_config.mode), AREagernessDescribe(_config.eagerness),
        _config.raiseAfterMillis];
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
    if (![self needsEvaluation]) { return @"Warping only"; }
    NSString *action = _config.focusFirst
        ? (_config.raises ? @"Focusing, then raising" : @"Focusing") : @"Raising";
    return [NSString stringWithFormat: @"%@, %@", action,
        AREagernessDescribe(_config.eagerness)];
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
        if (config.focusFirst) {
            printf("! focusing without raising needs the SkyLight framework, which is "
                   "missing: raising instead\n\n");
            config.mode = ARHoverModeRaise;
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
