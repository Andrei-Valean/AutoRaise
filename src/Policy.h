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

// How one application should be treated, whatever the general setting says. The
// table that stores these lives in AppTable.h; the vocabulary lives here,
// because the decision is made in this file.
typedef NS_ENUM(NSInteger, ARAppPolicy) {
    ARAppPolicyDefault = 0,   // whatever the general mode says
    ARAppPolicyRaise,         // bring its windows forward on hover
    ARAppPolicyFocus,         // give them the keyboard, leave them where they are
    ARAppPolicyQuiet,         // focus the application, do not name the window
    ARAppPolicyIgnore,        // never touch it
    ARAppPolicyKeepFocus,     // while it is in front, hovering elsewhere changes nothing
};

BOOL ARAppPolicyParse(NSString *_Nullable text, ARAppPolicy *policy);
NSString *ARAppPolicyDescribe(ARAppPolicy policy);
NSArray<NSString *> *ARAppPolicyNames(void);   // for the settings window, in menu order

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
// Buttons the pointer is never parked on, however the dialog aims it. Regular
// expressions against the button's title, so other languages can be added
// without a release.
@property (nonatomic, copy) NSArray<NSString *> *destructiveButtons;
@end

//------------------------------------------------------------------------------------------------
// Where the pointer goes when a dialog appears.
//
// A modal dialog is the one moment on screen where the next click is almost
// certain: there are two or three buttons and nothing else can be touched. The
// pointer may as well be on the one you meant, the same way it lands in the
// window you switch to.
//------------------------------------------------------------------------------------------------

typedef NS_ENUM(NSInteger, ARDialogAim) {
    ARDialogAimOff = 0,
    ARDialogAimDefault,    // the button Return would press: OK, Save, Yes
    ARDialogAimCancel,     // the button Escape would press
    ARDialogAimNearest,    // whichever is nearest, so the pointer moves least
};

BOOL ARDialogAimParse(NSString *_Nullable text, ARDialogAim *aim);
NSString *ARDialogAimDescribe(ARDialogAim aim);

@interface ARDialogButton : NSObject
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic) BOOL isDefault;    // kAXDefaultButtonAttribute of the window
@property (nonatomic) BOOL isCancel;     // kAXCancelButtonAttribute
@property (nonatomic) BOOL enabled;
@property (nonatomic) CGRect frame;
// The AXUIElement it came from, retained, so the window's default and cancel
// buttons are recognised by identity rather than by a localized title. Opaque
// here: nothing in the decision layer touches the accessibility API.
@property (nonatomic) void *element;
@end

typedef struct {
    NSInteger index;             // -1: leave the pointer where it is
    BOOL avoidedDestructive;     // the aim landed on Delete, so it moved to safety
} ARDialogTarget;

// Never parks the pointer on a destructive button, whatever the aim says: one
// stray click on Delete costs more than every click this feature saves.
ARDialogTarget ARChooseDialogButton(NSArray<ARDialogButton *> *buttons, ARDialogAim aim,
                                    CGPoint pointer, ARQuirks *_Nullable quirks);

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
@property (nonatomic) pid_t ownPid;          // AutoRaise never raises itself
// What the app table says about the hovered window's application, and about the
// one that currently holds the keyboard.
@property (nonatomic) ARAppPolicy hoveredPolicy;
@property (nonatomic) ARAppPolicy focusedPolicy;
@property (nonatomic) BOOL focusFirst;
@property (nonatomic, copy) NSArray<NSString *> *ignoreApps;
@property (nonatomic, copy) NSArray<NSString *> *ignoreTitles;
@property (nonatomic, strong) ARQuirks *quirks;
// Set this and every rule that had a say appends a line to it, ending with the
// one that decided. Nil, which it normally is, costs nothing.
@property (nonatomic, strong, nullable) NSMutableArray<NSString *> *trace;
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
// One line saying what the decision amounts to, for the inspector.
NSString *ARDecisionSummary(ARRaiseQuery *query, ARRaiseDecision decision, BOOL focusFirst);

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

// Intent, read from how the pointer is moving rather than from a stopwatch.
//
// A pointer crossing a window on its way somewhere else and a pointer arriving
// at one look identical if all you know is where it is, which is why the old
// model needed a delay, a dead zone and a stop requirement to tell them apart.
// Speed tells them apart on its own: travelling fast is transit, slowing to a
// halt is arrival.
// Faster than any hand can move a mouse: a sample this quick is the pointer
// being put somewhere by software, not travelling there.
#define AR_TELEPORT_SPEED 20000.0

typedef struct {
    CGFloat settleSpeed;        // points per second at or below which it has arrived
    NSTimeInterval confirm;     // how long it has to stay there first
    CGFloat jitter;             // movements smaller than this are a shaky hand
} ARIntentTuning;

typedef struct {
    CGFloat speed;              // points per second, smoothed
    BOOL settled;               // the pointer has arrived somewhere
    BOOL arrived;               // it settled on this very sample
} ARIntent;

// Fed one pointer position per event, in any order of arrival, and reports
// whether the pointer is travelling or has arrived.
@interface ARIntentReader : NSObject
- (instancetype)initWithTuning:(ARIntentTuning)tuning;
@property (nonatomic) ARIntentTuning tuning;
@property (nonatomic, readonly) ARIntent intent;
- (ARIntent)addPoint:(CGPoint)point atTime:(NSTimeInterval)time;
// A pointer that has not moved for a while has certainly arrived, even if no
// event ever said so.
- (ARIntent)settleAtTime:(NSTimeInterval)time;
- (void)reset;
@end

// Named tunings, because "how eager should it be" is the only question a person
// has about timing.
typedef NS_ENUM(NSInteger, AREagerness) {
    AREagernessInstant = 0,
    AREagernessQuick,
    AREagernessNormal,
    AREagernessRelaxed,
};

ARIntentTuning ARTuningFor(AREagerness eagerness);
BOOL AREagernessParse(NSString *_Nullable text, AREagerness *eagerness);
NSString *AREagernessDescribe(AREagerness eagerness);

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
