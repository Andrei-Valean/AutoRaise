/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Policy: the decision layer.
 *
 * Nothing declared here calls the accessibility API, the window server or
 * NSWorkspace. It answers "should this window be raised" from facts that were
 * gathered elsewhere, which is what lets tests/policy_tests.mm exercise every
 * accumulated app quirk without accessibility permission or a running desktop.
 */

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Facts about one window plus the application owning it. All rectangles are in
// CoreGraphics coordinates (origin top-left of the primary display).
@interface ARWindow : NSObject
@property (nonatomic) BOOL known;               // facts were gathered
@property (nonatomic) pid_t pid;
@property (nonatomic) CGWindowID windowId;
@property (nonatomic, copy, nullable) NSString *title;      // nil: window has no AX title
@property (nonatomic, copy, nullable) NSString *appName;    // AX title of the app element
@property (nonatomic, copy, nullable) NSString *bundleId;
@property (nonatomic) BOOL isMain;               // kAXMainAttribute
@property (nonatomic) BOOL isDialog;             // kAXDialogSubrole
@property (nonatomic) BOOL isSystemDialog;       // kAXSystemDialogSubrole
@property (nonatomic) BOOL isFloating;           // (system) floating or unknown subrole
@property (nonatomic) BOOL hasFrame;
@property (nonatomic) CGRect frame;
@property (nonatomic) BOOL hasScreen;
@property (nonatomic) CGRect screenFrame;        // display holding the window
@property (nonatomic) CGFloat menuBarHeight;     // 0 when the menu bar is hidden
@end

// App-specific knowledge, built in by default and overridable from a data file.
// See Quirks.h.
@interface ARQuirks : NSObject
@property (nonatomic, copy) NSArray<NSString *> *mainWindowAppsWithoutTitle;
@property (nonatomic, copy) NSArray<NSString *> *pwaBrowsers;
@property (nonatomic, copy) NSArray<NSString *> *appsRaisingOnFocus;
@property (nonatomic, copy) NSArray<NSString *> *ignoreTitles;
@property (nonatomic, copy) NSArray<NSString *> *ignoreApps;
@property (nonatomic, copy) NSArray<NSString *> *finderApps;
@property (nonatomic, copy) NSArray<NSString *> *titlesNeedingMainWindowCheck;
@end

typedef struct {
    BOOL needsRaise;
    BOOL appRaisesOnFocus;   // this app raises itself when focused, see focusFirst
} ARRaiseDecision;

// Everything ARDecideRaise needs, gathered once per evaluation.
@interface ARRaiseQuery : NSObject
@property (nonatomic, strong) ARWindow *mouseWindow;
@property (nonatomic, strong) ARWindow *focusedWindow;   // known == NO: frontmost app has none
@property (nonatomic) BOOL mouseWindowPresent;           // window was not destroyed under us
@property (nonatomic) BOOL frontmostHasMainWindow;
@property (nonatomic) BOOL invertIgnoreApps;
@property (nonatomic) pid_t ownPid;          // AutoRaise never raises itself
@property (nonatomic) BOOL focusFirst;
@property (nonatomic, copy) NSArray<NSString *> *ignoreApps;
@property (nonatomic, copy) NSArray<NSString *> *ignoreTitles;
@property (nonatomic, strong) ARQuirks *quirks;
@end

// An app entry matches a localized app name (as AutoRaise has always done) or a
// bundle identifier, case insensitively. Bundle identifiers are the portable
// spelling: localized names differ per system language.
BOOL ARMatchesApp(ARWindow *window, NSArray<NSString *> *_Nullable entries);

// Exact titles first, then each pattern as an ICU regular expression. A window
// without a title matches when @"" is among the exact titles.
BOOL ARTitleMatches(NSString *_Nullable title,
                    NSArray<NSString *> *_Nullable exact,
                    NSArray<NSString *> *_Nullable patterns);

BOOL ARIsPWA(NSString *_Nullable bundleId, NSArray<NSString *> *browsers);
BOOL ARIsFullScreen(ARWindow *window);
BOOL ARIsMainWindow(ARWindow *window, ARQuirks *quirks);
BOOL ARContainedWithin(CGRect inner, CGRect outer);
BOOL ARWindowContainedWithin(ARWindow *inner, ARWindow *outer);

// The decision runs in two stages so that the focused window, which costs a
// round trip to the frontmost application, is only looked up when the hovered
// window is a candidate at all.
ARRaiseDecision ARDecideCandidate(ARRaiseQuery *query);
BOOL ARDecideAgainstFocused(ARRaiseQuery *query, ARRaiseDecision candidate);

// Both stages at once.
ARRaiseDecision ARDecideRaise(ARRaiseQuery *query);

// Mouse position corrections for the transparent window border macOS 12
// introduced, and for the menu bar and screen edges. Pure geometry so the
// off-by-one cases are testable.
typedef NS_ENUM(NSInteger, ARCorrection) {
    ARCorrectionNone = 0,
    ARCorrectionScreenEdge = 1 << 0,
    ARCorrectionMenuBar = 1 << 1,
};

typedef struct {
    CGPoint point;
    ARCorrection applied;
} ARCorrectedPoint;

ARCorrectedPoint ARCorrectMousePoint(CGPoint raw, CGPoint delta,
                                     BOOL hasScreen, CGRect screenFrame, CGFloat menuBarHeight);

// Delay bookkeeping. delayTicks counts down once per evaluation while the mouse
// rests on a raisable window; raiseTimes repeats the raise a few times because
// some apps swallow the first attempt.
typedef struct {
    int delayTicks;
    int raiseTimes;
} ARDelayState;

typedef struct {
    BOOL act;                // raise or focus now
    ARDelayState state;
} ARDelayStep;

#define AR_RAISE_REPEATS 3

ARDelayStep ARAdvanceDelay(ARDelayState state, int delayCount);
ARDelayState ARResetDelay(void);

NS_ASSUME_NONNULL_END
