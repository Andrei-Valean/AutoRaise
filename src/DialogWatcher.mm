/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "DialogWatcher.h"

#import "WindowFinder.h"

@implementation ARDialogWatcher {
    __weak id<ARDialogWatcherDelegate> _delegate;
    AXObserverRef _observer;
    CFRunLoopSourceRef _source;
    pid_t _watched;
    AXUIElementRef _app;
    // The dialog currently being reported, so the same one is not announced
    // twice and its disappearance can be noticed.
    AXUIElementRef _dialog;
    CGWindowID _dialogId;
}

static ARDialogWatcher *watcher = nil;

static void ARDialogObserverCallback(AXObserverRef observer, AXUIElementRef element,
                                     CFStringRef notification, void *refcon) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        [watcher noteDialogDestroyed: element];
    } else {
        [watcher noteWindowCreated: element];
    }
}

- (instancetype)initWithDelegate:(id<ARDialogWatcherDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _watched = 0;
        _dialogId = kCGNullWindowID;
        watcher = self;
    }
    return self;
}

- (void)dealloc { [self stop]; }

//------------------------------------------------ watching ------------------------------------------------

- (void)watchApplication:(pid_t)pid {
    if (pid == _watched || pid == getpid() || pid <= 0) { return; }
    [self stop];

    if (AXObserverCreate(pid, ARDialogObserverCallback, &_observer) != kAXErrorSuccess ||
        !_observer) {
        _observer = NULL;
        return;
    }
    _app = AXUIElementCreateApplication(pid);
    if (!_app) { [self stop]; return; }
    _watched = pid;

    // An alert is a new window; a sheet is announced separately, because it
    // belongs to a window that already exists.
    AXObserverAddNotification(_observer, _app, kAXWindowCreatedNotification, NULL);
    AXObserverAddNotification(_observer, _app, kAXSheetCreatedNotification, NULL);

    _source = AXObserverGetRunLoopSource(_observer);
    if (_source) { CFRunLoopAddSource(CFRunLoopGetCurrent(), _source, kCFRunLoopCommonModes); }

    // A question that is already on screen still needs answering, and it is
    // common for the asking application to come forward only once it is.
    AXUIElementRef _focused = ARCopyFocusedWindow(pid);
    if (_focused) {
        [self noteWindowCreated: _focused];
        CFRelease(_focused);
    }
}

- (void)stop {
    [self forgetDialog];
    if (_observer && _app) {
        AXObserverRemoveNotification(_observer, _app, kAXWindowCreatedNotification);
        AXObserverRemoveNotification(_observer, _app, kAXSheetCreatedNotification);
    }
    if (_source) {
        // Without this the run loop keeps the source, the source keeps the
        // observer, and one observer leaks per application ever activated.
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), _source, kCFRunLoopCommonModes);
        _source = NULL;
    }
    if (_app) { CFRelease(_app); _app = NULL; }
    if (_observer) { CFRelease(_observer); _observer = NULL; }
    _watched = 0;
}

//------------------------------------------------ reporting -----------------------------------------------

- (void)noteWindowCreated:(AXUIElementRef)window {
    if (!window || !ARWindowIsDialog(window)) { return; }

    CGWindowID windowId = ARWindowID(window);
    // The same dialog can be announced twice: created, then found again when
    // its application comes forward.
    if (_dialog && windowId != kCGNullWindowID && windowId == _dialogId) { return; }
    if (_dialog && CFEqual(_dialog, window)) { return; }

    [self forgetDialog];
    _dialog = (AXUIElementRef) CFRetain(window);
    _dialogId = windowId;
    if (_observer) {
        AXObserverAddNotification(_observer, window, kAXUIElementDestroyedNotification, NULL);
    }
    [_delegate dialogAppeared: window pid: _watched];
}

- (void)noteDialogDestroyed:(AXUIElementRef)element {
    if (!_dialog || !element || !CFEqual(_dialog, element)) { return; }
    [self forgetDialog];
    [_delegate dialogWentAway];
}

- (void)forgetDialog {
    if (!_dialog) { return; }
    if (_observer) {
        AXObserverRemoveNotification(_observer, _dialog, kAXUIElementDestroyedNotification);
    }
    CFRelease(_dialog);
    _dialog = NULL;
    _dialogId = kCGNullWindowID;
}

@end
