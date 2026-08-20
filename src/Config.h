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
// Whether raising is switched on at all, so pausing survives a restart.
@property (nonatomic) BOOL enabled;
// Global shortcut that toggles the above, "control-option-A" style, or nil.
@property (nonatomic, copy, nullable) NSString *toggleShortcut;
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

// Command line arguments override the file, which would quietly defeat the
// settings window. Changing one of those settings on purpose drops the
// argument, so the file wins from then on.
void ARConfigForgetArguments(NSArray<NSString *> *keys);

ARConfig *ARConfigFromValues(NSDictionary<NSString *, NSString *> *values,
                             NSArray<NSString *> *_Nullable warnings);

// A shortcut as stored in the settings file: modifier words and a key name
// joined by "-", for instance "control-option-A" or "command-shift-F5".
typedef struct {
    BOOL valid;
    unsigned short keyCode;
    CGEventFlags modifiers;
} ARShortcut;

ARShortcut ARShortcutParse(NSString *_Nullable text);
NSString *_Nullable ARShortcutDescribe(ARShortcut shortcut);   // for the settings file
NSString *ARShortcutDisplay(ARShortcut shortcut);              // ⌃⌥A, for the interface

// Parsers, separated out so tests can hit the awkward cases.
NSDictionary<NSString *, NSString *> *ARConfigParseFile(NSString *contents,
                                                        NSMutableArray<NSString *> *_Nullable warnings);
NSDictionary<NSString *, NSString *> *ARConfigParseArguments(int argc, const char *_Nonnull argv[_Nullable],
                                                             NSMutableArray<NSString *> *_Nullable warnings);
NSArray<NSString *> *ARSplitList(NSString *_Nullable value, BOOL trimEntries);

// Updates settings in place: the line for each key is replaced, added, or with
// NSNull removed, and everything else in the file including comments is left
// alone. Creates the file from the template when it does not exist yet.
BOOL ARConfigWrite(NSString *path, NSDictionary<NSString *, id> *changes, NSError *_Nullable *_Nullable error);

// The settings file, created from the template if there is none yet.
NSString *_Nullable ARConfigEnsurePath(NSError *_Nullable *_Nullable error);

NSString *_Nullable ARConfigExistingPath(void);   // file AutoRaise would read
NSString *ARConfigPreferredPath(void);            // where to create one
NSString *ARConfigTemplate(void);                 // starter file contents
NSString *ARConfigSummary(ARConfig *config);      // startup report
NSString *ARConfigUsage(void);

NS_ASSUME_NONNULL_END
