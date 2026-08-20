/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Config: defaults, then the config file, then command line arguments.
 *
 * Every setting that used to be a compile time flag lives here, so one binary
 * behaves like every build variant AutoRaise used to ship.
 */

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface ARConfig : NSObject

// Timing. delay and focusDelay are counted in evaluations, as they always were:
// 0 disables, 1 acts immediately, n waits (n-1) * pollMillis.
@property (nonatomic) int pollMillis;
@property (nonatomic) int heartbeatMillis;   // idle safety net, 0 disables
@property (nonatomic) int delayTicks;
@property (nonatomic) int focusDelayTicks;

// Mouse warping on task switch.
@property (nonatomic) float warpX;
@property (nonatomic) float warpY;
@property (nonatomic) float cursorScale;
@property (nonatomic, readonly) BOOL warpMouse;

@property (nonatomic) BOOL altTaskSwitcher;
@property (nonatomic) BOOL requireMouseStop;
@property (nonatomic) BOOL ignoreSpaceChanged;
@property (nonatomic) BOOL invertDisableKey;
@property (nonatomic) BOOL invertIgnoreApps;
@property (nonatomic) float mouseDelta;

// Used to be OLD_ACTIVATION_METHOD, ALTERNATIVE_TASK_SWITCHER and
// EXPERIMENTAL_FOCUS_FIRST at compile time.
@property (nonatomic) BOOL legacyActivation;
@property (nonatomic) BOOL windowServerHitTest;

@property (nonatomic) BOOL menuBarIcon;
@property (nonatomic) BOOL liveReload;
@property (nonatomic) BOOL verbose;

@property (nonatomic) CGEventFlags disableKey;
@property (nonatomic, copy) NSString *disableKeyName;

@property (nonatomic, copy) NSArray<NSString *> *ignoreApps;
@property (nonatomic, copy) NSArray<NSString *> *ignoreTitles;
@property (nonatomic, copy) NSArray<NSString *> *stayFocusedBundleIds;

// Where the settings came from, and anything the user should know about them.
@property (nonatomic, copy, nullable) NSString *sourcePath;
@property (nonatomic, copy) NSArray<NSString *> *warnings;

// Derived: focus the hovered window first and raise it later (or never).
@property (nonatomic, readonly) BOOL focusFirst;
@property (nonatomic, readonly) int primaryDelayTicks;   // drives the delay countdown
@property (nonatomic, readonly) int raiseAfterFocusTicks;

@end

// One shot load: defaults, config file, then argv. Also handles -config <path>.
ARConfig *ARConfigLoad(int argc, const char *_Nonnull argv[_Nullable]);

// Re-read the same source, for live reload.
ARConfig *ARConfigReload(ARConfig *previous);

ARConfig *ARConfigFromValues(NSDictionary<NSString *, NSString *> *values,
                             NSArray<NSString *> *_Nullable warnings);

// Parsers, separated out so tests can hit the awkward cases.
NSDictionary<NSString *, NSString *> *ARConfigParseFile(NSString *contents,
                                                        NSMutableArray<NSString *> *_Nullable warnings);
NSDictionary<NSString *, NSString *> *ARConfigParseArguments(int argc, const char *_Nonnull argv[_Nullable],
                                                             NSMutableArray<NSString *> *_Nullable warnings);
NSArray<NSString *> *ARSplitList(NSString *_Nullable value, BOOL trimEntries);

NSString *_Nullable ARConfigExistingPath(void);   // file AutoRaise would read
NSString *ARConfigPreferredPath(void);            // where to create one
NSString *ARConfigTemplate(void);                 // starter file contents
NSString *ARConfigSummary(ARConfig *config);      // startup report
NSString *ARConfigUsage(void);

NS_ASSUME_NONNULL_END
