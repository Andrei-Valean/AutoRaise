/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * WindowPin: keeps chosen windows above everything else.
 *
 * The window server will not let one application change the level of another
 * application's window, so a pinned window is not actually moved. AutoRaise
 * shows a live copy of it in a floating panel of its own, exactly where the
 * real window is, whenever something else is in front of it. Hovering the copy
 * hovers the real window; clicking it brings the real window forward, at which
 * point the copy steps aside because nothing is covering the original any more.
 *
 * The copy is drawn by ScreenCaptureKit, so pinning needs the Screen Recording
 * permission on top of accessibility.
 */

#pragma once

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

extern BOOL ARWindowPinVerbose;

@class ARWindowPins;

@interface ARPinnedWindow : NSObject
@property (nonatomic, readonly) CGWindowID windowId;
@property (nonatomic, readonly) pid_t pid;
// The real window. Owned by the pin; valid for as long as it is pinned.
@property (nonatomic, readonly) AXUIElementRef window;
// "Terminal: ~/src", for menus and logs.
@property (nonatomic, readonly, copy) NSString *name;
// Whether the copy is on screen, standing in for a covered original.
@property (nonatomic, readonly) BOOL showingCopy;
@end

@protocol ARWindowPinsDelegate <NSObject>
// The copy was clicked: the real window should come forward.
- (void)pinnedWindowWasClicked:(ARPinnedWindow *)pin;
@end

@interface ARWindowPins : NSObject

- (instancetype)initWithDelegate:(id<ARWindowPinsDelegate>)delegate;

@property (nonatomic, readonly) NSArray<ARPinnedWindow *> *pins;

// Pins a window, or lets go of it when it is already pinned. Returns a sentence
// saying what happened, or why nothing did, for the log and the inspector.
- (NSString *)togglePinOf:(AXUIElementRef)window;

// The pin whose copy is on screen at a point, in CoreGraphics coordinates.
// Hit tests ask this first: the window server would answer with the copy,
// which belongs to AutoRaise, rather than with the window it stands for.
- (nullable ARPinnedWindow *)pinShowingCopyAt:(CGPoint)point;
// Whether this window is pinned and its copy is what is on screen.
- (BOOL)isShowingCopyOf:(CGWindowID)windowId;

- (void)unpin:(ARPinnedWindow *)pin;
- (void)unpinAll;

// Something may have changed which window is in front: a click, another
// application activating, a desktop switch. Checks again straight away and
// a couple of times while the change lands, instead of at the next poll.
- (void)stackingMayHaveChanged;

@end

NS_ASSUME_NONNULL_END
