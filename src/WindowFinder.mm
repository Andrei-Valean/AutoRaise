/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "WindowFinder.h"

#include <libproc.h>

#define STACK_THRESHOLD 20
#define DOCK_CACHE_SECONDS 0.15

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);

#if SKYLIGHT_AVAILABLE
// Undocumented, and the reason the window server hit test is switchable: one
// call tells us which window is on top at a point without waiting for the
// application that owns it.
extern "C" CGError SLSFindWindowByGeometry(int cid, int filter, int one, int zero,
                                           CGPoint *screenPoint, CGPoint *windowPoint,
                                           uint32_t *windowId, int *windowConnection);
#endif

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

BOOL ARWindowServerHitTestAvailable(void) {
#if SKYLIGHT_AVAILABLE
    return YES;
#else
    return NO;
#endif
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
    if (_AXUIElementGetWindow(window, &windowId) != kAXErrorSuccess) {
        // Never let a failed lookup leave a stale id behind: kCGNullWindowID
        // means "unknown", which callers handle.
        return kCGNullWindowID;
    }
    return windowId;
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
        if (_AXUIElementGetWindow(_candidate, &candidateId) == kAXErrorSuccess &&
            candidateId == windowId) {
            _match = (AXUIElementRef) CFRetain(_candidate);
            break;
        }
    }
    return _match;
}

// The topmost normal window at a point according to the window server, plus its
// owner. Returns NO when the point is over the menu bar, the Dock, a screen
// saver or anything else that is not a normal window.
static BOOL ARWindowServerWindowAtPoint(CGPoint point, CGWindowID *windowId, pid_t *pid) {
#if SKYLIGHT_AVAILABLE
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
    return *pid != 0;
#else
    (void) point; (void) windowId; (void) pid;
    return NO;
#endif
}

// The pre-window-server route: scan the on screen window list top to bottom.
// Still used when SkyLight is unavailable.
static BOOL ARListWindowAtPoint(CGPoint point, CGWindowID *windowId, pid_t *pid) {
    NSArray *windows = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *window in windows) {
        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }
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
