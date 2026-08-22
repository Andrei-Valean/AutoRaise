/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "WindowFinder.h"

#include <libproc.h>

#define STACK_THRESHOLD 20
#define DOCK_CACHE_SECONDS 0.15

// Undocumented, and the reason the window server hit test is switchable: one
// call tells us which window is on top at a point without waiting for the
// application that owns it.
//
// Weakly imported, every one of them. These are private symbols, so a future
// macOS may rename or drop one, and a hard reference would stop AutoRaise from
// launching at all. Weak, a missing symbol is a null pointer, and the check
// before each call falls back to asking the application instead.
typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void) __attribute__((weak_import));
extern "C" CGError SLSFindWindowByGeometry(int cid, int filter, int one, int zero,
                                           CGPoint *screenPoint, CGPoint *windowPoint,
                                           uint32_t *windowId, int *windowConnection)
    __attribute__((weak_import));

static AXUIElementRef _systemWide = NULL;
static AXUIElementRef _dockApp = NULL;
static CGPoint desktopOrigin = {0, 0};
static BOOL verboseLogging = NO;
// Which route the deepest fallback should take, set per evaluation so the
// accessibility strategy never silently borrows the window server one.
static BOOL fallbackPrefersWindowServer = YES;

static NSString *const XQuartz = @"XQuartz";

void ARWindowFinderSetVerbose(BOOL verbose) { verboseLogging = verbose; }

static void ARFindDockApplication(void) {
    if (_dockApp) { CFRelease(_dockApp); _dockApp = NULL; }
    for (NSRunningApplication *app in [[NSWorkspace sharedWorkspace] runningApplications]) {
        if ([app.bundleIdentifier isEqualToString: @"com.apple.dock"]) {
            _dockApp = AXUIElementCreateApplication(app.processIdentifier);
            AXUIElementSetMessagingTimeout(_dockApp, AR_AX_TIMEOUT);
            return;
        }
    }
    if (verboseLogging) { NSLog(@"Dock application isn't running"); }
}

// The Dock restarts now and then, taking its pid with it.
void ARWindowFinderRefreshDock(void) { ARFindDockApplication(); }

void ARWindowFinderInit(BOOL verbose) {
    verboseLogging = verbose;
    _systemWide = AXUIElementCreateSystemWide();
    // Applies process wide: no accessibility request can stall the run loop for
    // longer than this, whatever state the hovered application is in.
    AXUIElementSetMessagingTimeout(_systemWide, AR_AX_TIMEOUT);
    ARFindDockApplication();
    ARRefreshDesktopOrigin();
}

BOOL ARPrivateCallsRefused(void) {
    static BOOL refused = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        refused = getenv("AUTORAISE_NO_PRIVATE") != NULL;
        if (refused) { NSLog(@"AUTORAISE_NO_PRIVATE: pretending the private calls are gone"); }
    });
    return refused;
}

BOOL ARWindowIdsAvailable(void) {
    return !ARPrivateCallsRefused() && _AXUIElementGetWindow != NULL;
}

BOOL ARWindowServerHitTestAvailable(void) {
    return !ARPrivateCallsRefused() &&
           SLSFindWindowByGeometry != NULL && CGSMainConnectionID != NULL;
}

//------------------------------------------------ logging -------------------------------------------------

static NSString *_Nullable ARCopyStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(element, attribute, &value);
    if (!value) { return nil; }
    NSString *result = nil;
    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        result = [NSString stringWithString: (__bridge NSString *) value];
    }
    CFRelease(value);
    return result;
}

void ARLogWindowTitle(NSString *prefix, AXUIElementRef window) {
    if (!window) { NSLog(@"%@: null", prefix); return; }
    NSString *title = ARCopyStringAttribute(window, kAXTitleAttribute);
    if (title) { NSLog(@"%@: `%@`", prefix, title); return; }
    pid_t pid = 0;
    if (AXUIElementGetPid(window, &pid) == kAXErrorSuccess) {
        NSString *name = [NSRunningApplication runningApplicationWithProcessIdentifier: pid].localizedName;
        if (name) { NSLog(@"%@ (app name): `%@`", prefix, name); return; }
    }
    NSLog(@"%@: null", prefix);
}

//------------------------------------------------ geometry ------------------------------------------------

// NSScreen frames have their origin at the bottom left of the primary display;
// everything else here works in CoreGraphics coordinates.
static CGRect ARScreenFrameCG(NSScreen *screen) {
    NSScreen *primary = NSScreen.screens.firstObject;
    CGFloat top = NSMaxY(primary.frame);
    return CGRectMake(NSMinX(screen.frame), top - NSMaxY(screen.frame),
                      NSWidth(screen.frame), NSHeight(screen.frame));
}

static CGFloat ARMenuBarHeight(NSScreen *screen) {
    return fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
}

static NSScreen *_Nullable ARFindScreen(CGPoint point) {
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) { return nil; }
    point.y = NSMaxY(primary.frame) - point.y;
    for (NSScreen *screen in NSScreen.screens) {
        // One pixel of slack: the bottom and right edges are exclusive.
        NSRect bounds = NSMakeRect(NSMinX(screen.frame), NSMinY(screen.frame),
                                   NSWidth(screen.frame) + 1, NSHeight(screen.frame) + 1);
        if (NSPointInRect(NSPointFromCGPoint(point), bounds)) { return screen; }
    }
    return nil;
}

BOOL ARScreenAtPoint(CGPoint point, CGRect *frame, CGFloat *menuBarHeight) {
    NSScreen *screen = ARFindScreen(point);
    if (!screen) { return NO; }
    if (frame) { *frame = ARScreenFrameCG(screen); }
    if (menuBarHeight) { *menuBarHeight = ARMenuBarHeight(screen); }
    return YES;
}

void ARRefreshDesktopOrigin(void) {
    desktopOrigin = CGPointZero;
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) { return; }
    CGFloat top = NSMaxY(primary.frame);
    for (NSScreen *screen in NSScreen.screens) {
        CGFloat originY = top - NSMaxY(screen.frame);
        if (originY < desktopOrigin.y) { desktopOrigin.y = originY; }
        if (NSMinX(screen.frame) < desktopOrigin.x) { desktopOrigin.x = NSMinX(screen.frame); }
    }
    if (verboseLogging) { NSLog(@"Desktop origin (%.0f, %.0f)", desktopOrigin.x, desktopOrigin.y); }
}

static BOOL ARCopyRect(AXUIElementRef element, CGRect *out) {
    AXValueRef _size = NULL;
    AXValueRef _pos = NULL;
    BOOL ok = NO;
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute, (CFTypeRef *) &_pos);
        if (_pos) {
            CGSize size;
            CGPoint origin;
            if (AXValueGetValue(_size, kAXValueTypeCGSize, &size) &&
                AXValueGetValue(_pos, kAXValueTypeCGPoint, &origin)) {
                *out = CGRectMake(origin.x, origin.y, size.width, size.height);
                ok = YES;
            }
            CFRelease(_pos);
        }
        CFRelease(_size);
    }
    return ok;
}

BOOL ARIsDesktopWindow(AXUIElementRef window) {
    CGRect frame;
    if (!ARCopyRect(window, &frame)) { return NO; }
    BOOL desktop = CGPointEqualToPoint(frame.origin, desktopOrigin);
    if (verboseLogging && desktop) { NSLog(@"Desktop window"); }
    return desktop;
}

CGWindowID ARWindowID(AXUIElementRef window) {
    CGWindowID windowId = kCGNullWindowID;
    if (!ARWindowIdsAvailable() || _AXUIElementGetWindow(window, &windowId) != kAXErrorSuccess) {
        // Never let a failed lookup leave a stale id behind: kCGNullWindowID
        // means "unknown", which callers handle.
        return kCGNullWindowID;
    }
    return windowId;
}

BOOL ARWindowFrame(AXUIElementRef window, CGRect *frame) {
    return ARCopyRect(window, frame);
}

//------------------------------------------------ dialogs -------------------------------------------------

// How deep to look for buttons. An alert puts them straight in the window; a
// sheet often wraps them in a group or two. Deeper than this is a form, not a
// confirmation.
#define AR_BUTTON_SEARCH_DEPTH 3
#define AR_BUTTON_SEARCH_LIMIT 60

BOOL ARWindowIsDialog(AXUIElementRef window) {
    NSString *role = ARCopyStringAttribute(window, kAXRoleAttribute);
    if ([role isEqualToString: (__bridge NSString *) kAXSheetRole]) { return YES; }

    NSString *subrole = ARCopyStringAttribute(window, kAXSubroleAttribute);
    return [subrole isEqualToString: (__bridge NSString *) kAXDialogSubrole] ||
           [subrole isEqualToString: (__bridge NSString *) kAXSystemDialogSubrole];
}

static BOOL ARBooleanAttribute(AXUIElementRef element, CFStringRef attribute, BOOL fallback) {
    CFTypeRef _value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &_value) != kAXErrorSuccess || !_value) {
        return fallback;
    }
    BOOL value = CFGetTypeID(_value) == CFBooleanGetTypeID() ? CFBooleanGetValue((CFBooleanRef) _value)
                                                            : fallback;
    CFRelease(_value);
    return value;
}

static AXUIElementRef ARCopyElementAttribute(AXUIElementRef element, CFStringRef attribute) {
    AXUIElementRef _found = NULL;
    AXUIElementCopyAttributeValue(element, attribute, (CFTypeRef *) &_found);
    return _found;
}

// Depth first, so the buttons come back in the order the dialog lays them out.
static void ARCollectButtons(AXUIElementRef element, NSMutableArray *into, int depth, int *visited) {
    if (depth < 0 || *visited > AR_BUTTON_SEARCH_LIMIT) { return; }

    CFArrayRef _children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute,
                                      (CFTypeRef *) &_children) != kAXErrorSuccess || !_children) {
        return;
    }
    for (CFIndex i = 0; i < CFArrayGetCount(_children) && *visited <= AR_BUTTON_SEARCH_LIMIT; i++) {
        AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
        (*visited)++;
        NSString *role = ARCopyStringAttribute(child, kAXRoleAttribute);
        if ([role isEqualToString: (__bridge NSString *) kAXButtonRole]) {
            ARDialogButton *button = [[ARDialogButton alloc] init];
            button.title = ARCopyStringAttribute(child, kAXTitleAttribute);
            button.enabled = ARBooleanAttribute(child, kAXEnabledAttribute, YES);
            CGRect frame = CGRectZero;
            if (!ARCopyRect(child, &frame)) { continue; }
            button.frame = frame;
            // Kept so the default and cancel ones can be recognised by identity
            // rather than by title, which is localized.
            button.element = (void *) CFRetain(child);
            [into addObject: button];
        } else {
            ARCollectButtons(child, into, depth - 1, visited);
        }
    }
    CFRelease(_children);
}

NSArray<ARDialogButton *> *ARDialogButtons(AXUIElementRef window) {
    NSMutableArray<ARDialogButton *> *buttons = [NSMutableArray array];
    int visited = 0;
    ARCollectButtons(window, buttons, AR_BUTTON_SEARCH_DEPTH, &visited);

    // The dialog itself says which button each key would press, which is the
    // only way to know it without reading localized titles.
    AXUIElementRef _default = ARCopyElementAttribute(window, kAXDefaultButtonAttribute);
    AXUIElementRef _cancel = ARCopyElementAttribute(window, kAXCancelButtonAttribute);
    for (ARDialogButton *button in buttons) {
        AXUIElementRef element = (AXUIElementRef) button.element;
        if (_default && CFEqual(element, _default)) { button.isDefault = YES; }
        if (_cancel && CFEqual(element, _cancel)) { button.isCancel = YES; }
    }
    if (_default) { CFRelease(_default); }
    if (_cancel) { CFRelease(_cancel); }

    if (verboseLogging) {
        for (ARDialogButton *button in buttons) {
            NSLog(@"Dialog button \"%@\"%@%@%@", button.title,
                  button.isDefault ? @" (default)" : @"", button.isCancel ? @" (cancel)" : @"",
                  button.enabled ? @"" : @" (disabled)");
        }
    }
    return buttons;
}

BOOL ARDialogWantsTyping(pid_t pid) {
    AXUIElementRef _app = AXUIElementCreateApplication(pid);
    if (!_app) { return NO; }
    AXUIElementRef _focused = ARCopyElementAttribute(_app, kAXFocusedUIElementAttribute);
    CFRelease(_app);
    if (!_focused) { return NO; }

    NSString *role = ARCopyStringAttribute(_focused, kAXRoleAttribute);
    CFRelease(_focused);
    return [role isEqualToString: (__bridge NSString *) kAXTextFieldRole] ||
           [role isEqualToString: (__bridge NSString *) kAXTextAreaRole] ||
           [role isEqualToString: (__bridge NSString *) kAXComboBoxRole];
}

NSArray<NSValue *> *ARWindowsInFrontOf(CGWindowID windowId) {
    NSMutableArray<NSValue *> *inFront = [NSMutableArray array];
    if (windowId == kCGNullWindowID) { return inFront; }

    NSArray *windows = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    pid_t own = getpid();
    for (NSDictionary *window in windows) {
        // The list runs front to back, so everything before the window itself
        // is in front of it.
        if ([window[(__bridge id) kCGWindowNumber] unsignedIntValue] == windowId) { break; }
        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
        if ([window[(__bridge id) kCGWindowOwnerPID] intValue] == own) { continue; }

        NSDictionary *bounds = window[(__bridge id) kCGWindowBounds];
        [inFront addObject: [NSValue valueWithRect: NSMakeRect(
            [bounds[@"X"] doubleValue], [bounds[@"Y"] doubleValue],
            [bounds[@"Width"] doubleValue], [bounds[@"Height"] doubleValue])]];
    }
    return inFront;
}

CGWindowID ARTopmostWindowId(void) {
    NSArray *windows = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    pid_t own = getpid();
    for (NSDictionary *window in windows) {
        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
        if ([window[(__bridge id) kCGWindowOwnerPID] intValue] == own) { continue; }
        return [window[(__bridge id) kCGWindowNumber] unsignedIntValue];
    }
    return kCGNullWindowID;
}

CGPoint ARWarpPointForWindow(AXUIElementRef window, float warpX, float warpY) {
    CGRect frame;
    if (!ARCopyRect(window, &frame)) { return CGPointZero; }
    return CGPointMake(frame.origin.x + frame.size.width * warpX,
                       frame.origin.y + frame.size.height * warpY);
}

//---------------------------------------------- dock state ------------------------------------------------

static NSTimeInterval dockCheckedAt = 0;
static BOOL dockActiveCached = NO;
static BOOL missionControlCached = NO;

void ARInvalidateDockCache(void) { dockCheckedAt = 0; }

static void ARRefreshDockState(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - dockCheckedAt < DOCK_CACHE_SECONDS) { return; }
    dockCheckedAt = now;
    dockActiveCached = NO;
    missionControlCached = NO;
    if (!_dockApp) { return; }

    AXUIElementRef _focused = NULL;
    AXUIElementCopyAttributeValue(_dockApp, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focused);
    if (_focused) {
        dockActiveCached = YES;
        CFRelease(_focused);
        if (verboseLogging) { NSLog(@"Dock is active"); }
    }

    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dockApp, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i = 0; !missionControlCached && i < count; i++) {
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            NSString *role = ARCopyStringAttribute(_element, kAXRoleAttribute);
            if ([role isEqualToString: (__bridge NSString *) kAXGroupRole]) {
                NSString *title = ARCopyStringAttribute(_element, kAXTitleAttribute);
                missionControlCached = [title isEqualToString: @"Mission Control"];
            }
        }
        CFRelease(_children);
        if (verboseLogging && missionControlCached) { NSLog(@"Mission Control is active"); }
    }
}

BOOL ARDockIsActive(void) { ARRefreshDockState(); return dockActiveCached; }
BOOL ARMissionControlIsActive(void) { ARRefreshDockState(); return missionControlCached; }

//------------------------------------------- window at a point --------------------------------------------

// Maps a window server id onto the accessibility window of the same window.
static AXUIElementRef _Nullable ARCopyAXWindowForID(pid_t pid, CGWindowID windowId) {
    if (!windowId) { return NULL; }
    AXUIElementRef _app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_app, AR_AX_TIMEOUT);
    CFTypeRef _windows = NULL;
    AXUIElementCopyAttributeValue(_app, kAXWindowsAttribute, &_windows);
    CFRelease(_app);
    if (!_windows) { return NULL; }

    AXUIElementRef _match = NULL;
    NSArray *windows = (NSArray *) CFBridgingRelease(_windows);
    for (id candidate in windows) {
        AXUIElementRef _candidate = (__bridge AXUIElementRef) candidate;
        CGWindowID candidateId = kCGNullWindowID;
        if (ARWindowIdsAvailable() &&
            _AXUIElementGetWindow(_candidate, &candidateId) == kAXErrorSuccess &&
            candidateId == windowId) {
            _match = (AXUIElementRef) CFRetain(_candidate);
            break;
        }
    }
    return _match;
}

static BOOL ARListWindowAtPoint(CGPoint point, CGWindowID *windowId, pid_t *pid);

// The topmost normal window at a point according to the window server, plus its
// owner. Returns NO when the point is over the menu bar, the Dock, a screen
// saver or anything else that is not a normal window.
static BOOL ARWindowServerWindowAtPoint(CGPoint point, CGWindowID *windowId, pid_t *pid) {
    if (!ARWindowServerHitTestAvailable()) { return NO; }

    CGPoint windowPoint = CGPointZero;
    uint32_t found = 0;
    int connection = 0;
    if (SLSFindWindowByGeometry(CGSMainConnectionID(), 0, 1, 0,
                                &point, &windowPoint, &found, &connection) != kCGErrorSuccess) {
        return NO;
    }
    if (!found) { return NO; }

    const void *ids[1] = {(const void *) (uintptr_t) found};
    CFArrayRef _ids = CFArrayCreate(NULL, ids, 1, NULL);
    NSArray *description = (NSArray *) CFBridgingRelease(CGWindowListCreateDescriptionFromArray(_ids));
    CFRelease(_ids);

    NSDictionary *info = description.firstObject;
    if (!info) { return NO; }
    if (![info[(__bridge id) kCGWindowLayer] isEqual: @0]) {
        if (verboseLogging) { NSLog(@"Window server: layer %@, not raisable", info[(__bridge id) kCGWindowLayer]); }
        return NO;
    }
    *windowId = found;
    *pid = [info[(__bridge id) kCGWindowOwnerPID] intValue];
    if (*pid == getpid()) {
        // The focus ring sits at the same level as the window it outlines, so
        // the list has to be walked instead to find what is underneath it.
        if (verboseLogging) { NSLog(@"Window server found our own window, looking underneath"); }
        return ARListWindowAtPoint(point, windowId, pid);
    }
    return *pid != 0;
}

// The pre-window-server route: scan the on screen window list top to bottom.
// Still used when SkyLight is unavailable.
static BOOL ARListWindowAtPoint(CGPoint point, CGWindowID *windowId, pid_t *pid) {
    NSArray *windows = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    pid_t own = getpid();
    for (NSDictionary *window in windows) {
        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
        // Never AutoRaise's own windows: the focus ring is one of them.
        if ([window[(__bridge id) kCGWindowOwnerPID] intValue] == own) { continue; }
        NSDictionary *bounds = window[(__bridge id) kCGWindowBounds];
        NSRect frame = NSMakeRect([bounds[@"X"] intValue], [bounds[@"Y"] intValue],
                                  [bounds[@"Width"] intValue], [bounds[@"Height"] intValue]);
        if (NSPointInRect(NSPointFromCGPoint(point), frame)) {
            *windowId = [window[(__bridge id) kCGWindowNumber] intValue];
            *pid = [window[(__bridge id) kCGWindowOwnerPID] intValue];
            return *pid != 0;
        }
    }
    return NO;
}

static AXUIElementRef _Nullable ARCopyWindowFromWindowServer(CGPoint point, BOOL preferWindowServer) {
    CGWindowID windowId = kCGNullWindowID;
    pid_t pid = 0;
    BOOL found = preferWindowServer && ARWindowServerHitTestAvailable()
        ? ARWindowServerWindowAtPoint(point, &windowId, &pid)
        : ARListWindowAtPoint(point, &windowId, &pid);
    if (!found) { return NULL; }

    AXUIElementRef _window = ARCopyAXWindowForID(pid, windowId);
    if (!_window && verboseLogging) {
        NSLog(@"Window server found window %u of pid %d, but no accessibility window", windowId, pid);
    }
    return _window;
}

// Walks up from the element under the mouse until it finds something raisable.
static AXUIElementRef _Nullable ARCopyRaisableWindow(AXUIElementRef _element, CGPoint point, int depth) {
    if (!_element) { return NULL; }

    if (depth >= STACK_THRESHOLD) {
        if (verboseLogging) {
            NSLog(@"Stack threshold reached");
            pid_t pid = 0;
            if (AXUIElementGetPid(_element, &pid) == kAXErrorSuccess) {
                char path[PROC_PIDPATHINFO_MAXSIZE];
                if (proc_pidpath(pid, path, sizeof(path)) > 0) { NSLog(@"Application path: %s", path); }
            }
        }
        CFRelease(_element);
        return NULL;
    }

    AXUIElementRef _window = NULL;
    NSString *role = ARCopyStringAttribute(_element, kAXRoleAttribute);
    BOOL checkAttributes = role == nil;

    if ([role isEqualToString: (__bridge NSString *) kAXWindowRole] ||
        [role isEqualToString: (__bridge NSString *) kAXSheetRole] ||
        [role isEqualToString: (__bridge NSString *) kAXDrawerRole]) {
        return _element;   // ownership passes to the caller
    }

    if ([role isEqualToString: (__bridge NSString *) kAXDockItemRole] ||
        [role isEqualToString: (__bridge NSString *) kAXMenuItemRole] ||
        [role isEqualToString: (__bridge NSString *) kAXMenuRole] ||
        [role isEqualToString: (__bridge NSString *) kAXMenuBarRole] ||
        [role isEqualToString: (__bridge NSString *) kAXMenuBarItemRole]) {
        CFRelease(_element);
        return NULL;
    }

    if ([role isEqualToString: (__bridge NSString *) kAXApplicationRole]) {
        NSString *title = ARCopyStringAttribute(_element, kAXTitleAttribute);
        if ([title isEqualToString: XQuartz]) {
            // XQuartz raises and focuses its own windows, so the AutoRaise
            // delay and warp settings do not apply to it.
            pid_t pid = 0;
            if (AXUIElementGetPid(_element, &pid) == kAXErrorSuccess) {
                pid_t frontmost = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
                if (pid != frontmost) {
                    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
                        activateWithOptions: 0];
                }
            }
            CFRelease(_element);
            return NULL;
        }
        checkAttributes = YES;
    } else if (role) {
        checkAttributes = YES;
    }

    if (checkAttributes) {
        AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
        BOOL noParent = _window == NULL;
        _window = ARCopyRaisableWindow(_window, point, depth + 1);
        if (!_window) {
            AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
            if (!_window && noParent) {
                _window = ARCopyWindowFromWindowServer(point, fallbackPrefersWindowServer);
            }
        }
        CFRelease(_element);
    }

    return _window;
}

static AXUIElementRef _Nullable ARCopyWindowFromAccessibility(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_systemWide, point.x, point.y, &_element);
    if (_element) { return ARCopyRaisableWindow(_element, point, 0); }

    switch (error) {
        case kAXErrorCannotComplete:      // app does not support accessibility, or is busy
        case kAXErrorNotImplemented:
        case kAXErrorIllegalArgument:     // progressive web apps
        case kAXErrorNoValue:             // sometimes right after a cmd-tab
            if (verboseLogging) { NSLog(@"Copy element: AXError %d, falling back", error); }
            return ARCopyWindowFromWindowServer(point, fallbackPrefersWindowServer);
        case kAXErrorAttributeUnsupported:  // volume or wifi menu bar window
        case kAXErrorFailure:               // the menu bar itself
            if (verboseLogging) { NSLog(@"Copy element: AXError %d, no window here", error); }
            return NULL;
        default:
            if (verboseLogging) { NSLog(@"Copy element: AXError %d", error); }
            return NULL;
    }
}

AXUIElementRef _Nullable ARCopyWindowAtPoint(CGPoint point, BOOL windowServerHitTest) {
    AXUIElementRef _window = NULL;
    fallbackPrefersWindowServer = windowServerHitTest;
    if (windowServerHitTest && ARWindowServerHitTestAvailable()) {
        _window = ARCopyWindowFromWindowServer(point, YES);
        // The window server knows the geometry but not the sheets and drawers
        // the accessibility tree exposes, so keep the old route as a fallback.
        if (!_window) { _window = ARCopyWindowFromAccessibility(point); }
    } else {
        _window = ARCopyWindowFromAccessibility(point);
    }

    if (verboseLogging) {
        if (_window) { ARLogWindowTitle(@"Mouse window", _window); }
        else { NSLog(@"No raisable window"); }
    }
    return _window;
}

//---------------------------------------------- facts -----------------------------------------------------

ARWindow *ARGatherWindow(AXUIElementRef window, BOOL includeGeometry) {
    ARWindow *facts = [[ARWindow alloc] init];
    if (!window) { return facts; }

    facts.known = YES;
    pid_t pid = 0;
    if (AXUIElementGetPid(window, &pid) == kAXErrorSuccess) { facts.pid = pid; }
    facts.windowId = ARWindowID(window);
    facts.title = ARCopyStringAttribute(window, kAXTitleAttribute);

    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier: facts.pid];
    facts.bundleId = app.bundleIdentifier;

    AXUIElementRef _app = AXUIElementCreateApplication(facts.pid);
    AXUIElementSetMessagingTimeout(_app, AR_AX_TIMEOUT);
    facts.appName = ARCopyStringAttribute(_app, kAXTitleAttribute) ?: app.localizedName;
    CFRelease(_app);

    CFBooleanRef _main = NULL;
    AXUIElementCopyAttributeValue(window, kAXMainAttribute, (CFTypeRef *) &_main);
    if (_main) {
        facts.isMain = CFEqual(_main, kCFBooleanTrue);
        CFRelease(_main);
    }

    NSString *subrole = ARCopyStringAttribute(window, kAXSubroleAttribute);
    if (subrole) {
        facts.isDialog = [subrole isEqualToString: (__bridge NSString *) kAXDialogSubrole];
        facts.isSystemDialog = [subrole isEqualToString: (__bridge NSString *) kAXSystemDialogSubrole];
        facts.isFloating =
            [subrole isEqualToString: (__bridge NSString *) kAXFloatingWindowSubrole] ||
            [subrole isEqualToString: (__bridge NSString *) kAXSystemFloatingWindowSubrole] ||
            [subrole isEqualToString: (__bridge NSString *) kAXUnknownSubrole];
    }

    if (includeGeometry) {
        CGRect frame;
        if (ARCopyRect(window, &frame)) {
            facts.hasFrame = YES;
            facts.frame = frame;
            CGRect screenFrame;
            CGFloat menuBarHeight = 0;
            if (ARScreenAtPoint(frame.origin, &screenFrame, &menuBarHeight)) {
                facts.hasScreen = YES;
                facts.screenFrame = screenFrame;
                facts.menuBarHeight = menuBarHeight;
            }
        }
    }

    return facts;
}

AXUIElementRef _Nullable ARCopyFocusedWindow(pid_t pid) {
    AXUIElementRef _app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_app, AR_AX_TIMEOUT);
    AXUIElementRef _window = NULL;
    AXUIElementCopyAttributeValue(_app, kAXFocusedWindowAttribute, (CFTypeRef *) &_window);
    CFRelease(_app);
    return _window;
}

BOOL ARApplicationHasMainWindow(pid_t pid) {
    AXUIElementRef _app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_app, AR_AX_TIMEOUT);
    AXUIElementRef _window = NULL;
    AXUIElementCopyAttributeValue(_app, kAXMainWindowAttribute, (CFTypeRef *) &_window);
    CFRelease(_app);
    if (!_window) { return NO; }
    CFRelease(_window);
    return YES;
}

AXUIElementRef _Nullable ARCopyActivatedWindow(pid_t pid) {
    AXUIElementRef _app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(_app, AR_AX_TIMEOUT);
    AXUIElementRef _window = NULL;
    AXUIElementCopyAttributeValue(_app, kAXMainWindowAttribute, (CFTypeRef *) &_window);
    if (!_window) {
        if (verboseLogging) { NSLog(@"No main window, trying focused window"); }
        AXUIElementCopyAttributeValue(_app, kAXFocusedWindowAttribute, (CFTypeRef *) &_window);
    }
    CFRelease(_app);
    return _window;
}
