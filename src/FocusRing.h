/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * FocusRing: the outline around a window that has the keyboard but was not
 * raised.
 *
 * Focus without raise is invisible otherwise. You type and hope. The ring says
 * which window is listening, and the raise shortcut brings that one forward.
 */

#pragma once

#import <AppKit/AppKit.h>

#import "Config.h"

NS_ASSUME_NONNULL_BEGIN

extern BOOL ARFocusRingVerbose;

@interface ARFocusRing : NSObject

@property (nonatomic) ARColor color;
@property (nonatomic) ARRingStyle style;
@property (nonatomic, readonly) BOOL visible;

// frame is the window frame in CoreGraphics coordinates, the same ones the
// accessibility API reports. windowId is the window being outlined: the ring is
// placed directly above it in the stacking order, so anything in front of that
// window covers the ring too. Pass kCGNullWindowID to float above everything,
// the copies of pinned windows included.
- (void)showAroundFrame:(CGRect)frame ofWindow:(CGWindowID)windowId;
- (void)hide;

@end

NS_ASSUME_NONNULL_END
