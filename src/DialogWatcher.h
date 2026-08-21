/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * DialogWatcher: notices when a dialog appears, and when it goes away.
 *
 * Warping the pointer into the window you switch to works because a task switch
 * says where you are about to click. A dialog says it far more precisely: the
 * screen has two or three buttons on it and nothing else can be touched until
 * one of them is pressed. So the pointer may as well already be there.
 *
 * The accessibility API announces this rather than having to be polled:
 * kAXWindowCreated for alerts, kAXSheetCreated for the sheets that slide out of
 * a title bar. Both arrive on the application element, so one observer per
 * application is enough, and the one being watched follows whichever
 * application is in front.
 */

#pragma once

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ARDialogWatcherDelegate <NSObject>
// A dialog appeared. The element is valid for the length of the call.
- (void)dialogAppeared:(AXUIElementRef)dialog pid:(pid_t)pid;
// The dialog reported above has gone, answered one way or another.
- (void)dialogWentAway;
@end

@interface ARDialogWatcher : NSObject

- (instancetype)initWithDelegate:(id<ARDialogWatcherDelegate>)delegate;

// Watch this application instead of whichever was being watched. Called when
// the frontmost application changes, since that is the one whose dialogs are
// about to be answered. A dialog already open when this is called counts as
// having appeared: an application that comes forward to ask something often
// activates only after the question is on screen.
- (void)watchApplication:(pid_t)pid;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
