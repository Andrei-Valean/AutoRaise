/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * WindowFinder: everything that talks to the accessibility API and the window
 * server. It answers "which window is under this point" and gathers the facts
 * Policy decides on.
 */

#pragma once

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

#import "Policy.h"

NS_ASSUME_NONNULL_BEGIN

// A hung application must never hang AutoRaise. Requests that take longer than
// this are abandoned and retried on the next evaluation.
#define AR_AX_TIMEOUT 0.2f

extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);

void ARWindowFinderInit(BOOL verbose);
void ARWindowFinderRefreshDock(void);
void ARWindowFinderSetVerbose(BOOL verbose);

// YES when the window server can be asked directly which window is at a point.
BOOL ARWindowServerHitTestAvailable(void);

// The window under point, retained, or NULL. windowServerHitTest asks the
// window server first and only falls back to walking the accessibility tree of
// the hovered application.
AXUIElementRef _Nullable ARCopyWindowAtPoint(CGPoint point, BOOL windowServerHitTest);

// Facts for Policy. Pass the owning application element when it is already at
// hand, otherwise it is created and released internally.
ARWindow *ARGatherWindow(AXUIElementRef window, BOOL includeGeometry);

// The focused window of the frontmost application, retained, or NULL.
AXUIElementRef _Nullable ARCopyFocusedWindow(pid_t pid);
BOOL ARApplicationHasMainWindow(pid_t pid);

// YES when the application has a panel on screen: a colour picker, an inspector
// palette, a find bar, anything AppKit puts above the normal windows. Those hide
// themselves the moment their application stops being frontmost, so taking the
// keyboard away from such an app makes the panel disappear. The answer is cached
// for a moment, because it costs a listing of every window on screen.
//
// ignoring leaves one window out of the count, which is how AutoRaise's own
// focus ring avoids being mistaken for a panel of its own.
BOOL ARApplicationHasPanel(pid_t pid, CGWindowID ignoring);

// The main (or focused) window of an application, retained, or NULL. Used by
// the mouse warping code on task switch.
AXUIElementRef _Nullable ARCopyActivatedWindow(pid_t pid);

CGWindowID ARWindowID(AXUIElementRef window);
// The window frame in CoreGraphics coordinates.
BOOL ARWindowFrame(AXUIElementRef window, CGRect *frame);

// Frames of the ordinary windows stacked in front of the given one, in
// CoreGraphics coordinates, front to back. AutoRaise's own windows are left
// out. Used to clip the focus ring to the part of a window you can actually
// see, since there is no way to place a window of ours inside another
// application's stacking order.
NSArray<NSValue *> *ARWindowsInFrontOf(CGWindowID windowId);
CGPoint ARWarpPointForWindow(AXUIElementRef window, float warpX, float warpY);

// Dock and Mission Control both take over the screen; raising underneath them
// fights the user. Answers are cached briefly because they cost two round trips
// to the Dock process.
BOOL ARDockIsActive(void);
BOOL ARMissionControlIsActive(void);
void ARInvalidateDockCache(void);

// Geometry of the display holding a point, in CoreGraphics coordinates.
BOOL ARScreenAtPoint(CGPoint point, CGRect *frame, CGFloat *menuBarHeight);
void ARRefreshDesktopOrigin(void);
BOOL ARIsDesktopWindow(AXUIElementRef window);

void ARLogWindowTitle(NSString *prefix, AXUIElementRef _Nullable window);

NS_ASSUME_NONNULL_END
