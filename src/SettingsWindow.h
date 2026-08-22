/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * SettingsWindow: every setting, in a window instead of a text file.
 *
 * Changes apply the moment they are made and are written straight to the
 * settings file, so the window, the file and a running AutoRaise never
 * disagree about anything.
 */

#pragma once

#import <AppKit/AppKit.h>

#import "Config.h"

NS_ASSUME_NONNULL_BEGIN

@protocol ARSettingsDelegate <NSObject>
- (ARConfig *)currentConfig;
// Keys as they appear in the settings file; NSNull removes one. Applied and
// persisted together.
- (void)applySettings:(NSDictionary<NSString *, id> *)changes;
- (void)resetAllSettings;
- (BOOL)accessibilityGranted;
- (void)requestAccessibility;
- (NSString *)statusSummary;
- (NSString *)diagnosticsReport;
- (BOOL)loginItemAvailable;
- (BOOL)loginItemEnabled;
- (void)setLoginItemEnabled:(BOOL)enabled;
- (nullable NSString *)settingsFilePath;
@end

@interface ARSettingsWindowController : NSWindowController
- (instancetype)initWithDelegate:(id<ARSettingsDelegate>)delegate;
- (void)show;
// Rebuilds every control from the current settings, after a reset or an edit
// made somewhere else.
- (void)rebuild;
@end

NS_ASSUME_NONNULL_END
