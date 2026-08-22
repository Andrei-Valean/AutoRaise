/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * MenuBar: the status item AutoRaise never had.
 *
 * Without it the only ways to pause or stop AutoRaise were Activity Monitor and
 * an AppleScript, and the only way to see whether accessibility was granted was
 * to notice nothing happening.
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ARMenuBarDelegate <NSObject>
- (BOOL)autoRaiseEnabled;
- (void)setAutoRaiseEnabled:(BOOL)enabled;
- (NSString *)statusSummary;         // one line, shown greyed out at the top
- (BOOL)accessibilityGranted;
- (void)requestAccessibility;
- (void)openSettings;
// The panel that says what AutoRaise is doing and why.
- (BOOL)inspectorVisible;
- (void)toggleInspector;
- (BOOL)loginItemAvailable;
- (BOOL)loginItemEnabled;
- (void)setLoginItemEnabled:(BOOL)enabled;
@end

@interface ARMenuBar : NSObject
- (instancetype)initWithDelegate:(id<ARMenuBarDelegate>)delegate;
- (void)refresh;
- (void)remove;
// The glyph, also used for the notification that AutoRaise needs permission.
+ (NSImage *)statusImage;
@end

NS_ASSUME_NONNULL_END
