/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Policy.h"

// The transparent border macOS 12 puts around every window. Two windows that
// look exactly adjacent actually overlap, so the mouse has to travel this far
// past the visual edge before the neighbour is considered hovered.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
#define SCREEN_EDGE_CORRECTION 1   // 1 <= value <= WINDOW_CORRECTION

@implementation ARWindow
@end

@implementation ARQuirks
@end

@implementation ARRaiseQuery
@end

BOOL ARMatchesApp(ARWindow *window, NSArray<NSString *> *entries) {
    if (!entries.count) { return NO; }
    for (NSString *entry in entries) {
        if (!entry.length) { continue; }
        if (window.appName && [window.appName isEqualToString: entry]) { return YES; }
        if (window.bundleId && [window.bundleId caseInsensitiveCompare: entry] == NSOrderedSame) { return YES; }
    }
    return NO;
}

BOOL ARTitleMatches(NSString *title, NSArray<NSString *> *exact, NSArray<NSString *> *patterns) {
    if (!title) { return [exact containsObject: @""]; }
    if ([exact containsObject: title]) { return YES; }
    for (NSString *pattern in patterns) {
        if (!pattern.length) { continue; }
        if ([title rangeOfString: pattern options: NSRegularExpressionSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

// Progressive web apps and pake wrappers get bundle identifiers shaped like
// com.google.Chrome.app.<hash> or com.<name>.pake. Their windows report no
// title, so they need the main window check rather than an outright skip.
BOOL ARIsPWA(NSString *bundleId, NSArray<NSString *> *browsers) {
    if (!bundleId) { return NO; }
    NSArray *parts = [bundleId componentsSeparatedByString: @"."];
    if (parts.count == 3 && [parts[1] isEqualToString: @"pake"]) { return YES; }
    return parts.count > 4 && [browsers containsObject: parts[2]] && [parts[3] isEqualToString: @"app"];
}

BOOL ARIsFullScreen(ARWindow *window) {
    if (!window.hasFrame || !window.hasScreen) { return NO; }
    CGRect screen = window.screenFrame;
    CGFloat menuBar = window.menuBarHeight;
    return window.frame.origin.x == screen.origin.x &&
           window.frame.origin.y == screen.origin.y + menuBar &&
           window.frame.size.width == screen.size.width &&
           window.frame.size.height == screen.size.height - menuBar;
}

BOOL ARIsMainWindow(ARWindow *window, ARQuirks *quirks) {
    BOOL main = window.isMain && !window.isDialog;
    BOOL finder = ARMatchesApp(window, quirks.finderApps);
    BOOL pwa = ARIsPWA(window.bundleId, quirks.pwaBrowsers);

    // A titled window is a real window. An untitled one only counts when the app
    // is known to leave its main window untitled, or when it is a browser-backed
    // web app, or when it is Finder (whose desktop window has no title either).
    main = main && (pwa || finder || window.title.length > 0 ||
                    ARMatchesApp(window, quirks.mainWindowAppsWithoutTitle));

    // A full screen window is always worth raising, except in Finder where the
    // desktop itself fills the screen.
    return main || (!finder && ARIsFullScreen(window));
}

BOOL ARContainedWithin(CGRect inner, CGRect outer) {
    return inner.origin.x > outer.origin.x &&
           inner.origin.y > outer.origin.y &&
           inner.origin.x + inner.size.width < outer.origin.x + outer.size.width &&
           inner.origin.y + inner.size.height < outer.origin.y + outer.size.height;
}

BOOL ARWindowContainedWithin(ARWindow *inner, ARWindow *outer) {
    if (!inner.hasFrame || !outer.hasFrame) { return NO; }
    return ARContainedWithin(inner.frame, outer.frame);
}

// Nothing here changes a decision; each line says which rule spoke and what it
// said, so the reason a window did or did not raise can be read rather than
// guessed at. The final line of a trace is always the rule that settled it.
static void ARNote(ARRaiseQuery *query, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
static void ARNote(ARRaiseQuery *query, NSString *format, ...) {
    if (!query.trace) { return; }
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat: format arguments: arguments];
    va_end(arguments);
    [query.trace addObject: line];
}

ARRaiseDecision ARDecideCandidate(ARRaiseQuery *query) {
    ARRaiseDecision decision = {NO, NO};
    ARWindow *mouse = query.mouseWindow;
    ARQuirks *quirks = query.quirks;

    // AutoRaise's own windows, the focus ring above all, are not candidates.
    if (query.ownPid && mouse.pid == query.ownPid) {
        ARNote(query, @"It is one of AutoRaise's own windows");
        return decision;
    }

    // One row in the app table beats every general setting.
    if (query.hoveredPolicy == ARAppPolicyIgnore) {
        ARNote(query, @"Its rule says leave it alone");
        return decision;
    }
    if (query.hoveredPolicy != ARAppPolicyDefault) {
        ARNote(query, @"Its rule says %@", ARAppPolicyDescribe(query.hoveredPolicy));
    }

    BOOL needsRaise = query.mouseWindowPresent;
    if (!needsRaise) { ARNote(query, @"No window under the pointer"); }

    if (needsRaise && ARTitleMatches(mouse.title, quirks.titlesNeedingMainWindowCheck, nil)) {
        needsRaise = ARIsMainWindow(mouse, quirks);
        ARNote(query, @"A quirk says to check this title is the main window: %@",
               needsRaise ? @"it is" : @"it is not");
    } else if (needsRaise && ARTitleMatches(mouse.title, quirks.ignoreTitles, query.ignoreTitles)) {
        needsRaise = NO;
        ARNote(query, @"Its title matches one to ignore");
    } else if (query.mouseWindowPresent) {
        if (query.hoveredPolicy == ARAppPolicyDefault &&
            (ARMatchesApp(mouse, query.ignoreApps) || ARMatchesApp(mouse, quirks.ignoreApps))) {
            needsRaise = NO;
            ARNote(query, @"The application is on a list to ignore");
        }
        decision.appRaisesOnFocus = query.hoveredPolicy == ARAppPolicyQuiet ||
                                    ARMatchesApp(mouse, quirks.appsRaisingOnFocus);
        if (decision.appRaisesOnFocus) {
            ARNote(query, @"It comes to the front by itself when focused");
        }
    }

    decision.needsRaise = needsRaise;
    return decision;
}

BOOL ARDecideAgainstFocused(ARRaiseQuery *query, ARRaiseDecision candidate) {
    if (!candidate.needsRaise) { return NO; }

    ARWindow *mouse = query.mouseWindow;
    ARWindow *focused = query.focusedWindow;
    if (!focused.known) {
        // The frontmost app has a main window but nothing focused: it is mid
        // transition, leave it alone.
        ARNote(query, query.frontmostHasMainWindow
            ? @"The frontmost application is between windows"
            : @"Nothing has the keyboard, so there is nothing to weigh it against");
        return !query.frontmostHasMainWindow;
    }

    if (mouse.windowId == focused.windowId) {
        ARNote(query, @"It already has the keyboard");
        return NO;
    }

    // A password prompt or another system dialog keeps the keyboard until it is
    // dealt with. Hovering past it must not take the focus away.
    if (focused.isSystemDialog) {
        ARNote(query, @"A system dialog has the keyboard and keeps it");
        return NO;
    }

    // Nor may an application whose row says it never loses the keyboard.
    if (query.focusedPolicy == ARAppPolicyKeepFocus && mouse.pid != focused.pid) {
        ARNote(query, @"The rule for the application in front says it never loses the keyboard");
        return NO;
    }

    // The focused window sitting inside the hovered one is what a dialog
    // belonging to it looks like, and raising the parent over its own dialog
    // would be wrong. Across applications the same geometry means nothing: a
    // small window parked on top of a big one, a calculator over an editor,
    // must not make the whole window underneath unhoverable.
    BOOL sameApp = mouse.pid == focused.pid;
    BOOL wouldCoverOwnDialog = sameApp && ARWindowContainedWithin(focused, mouse);

    if (wouldCoverOwnDialog) {
        ARNote(query, @"The window with the keyboard is a dialog belonging to this one");
    }
    if (!query.focusFirst) { return !wouldCoverOwnDialog; }

    BOOL focusedIsMain = ARIsMainWindow(focused, query.quirks);
    if (!focusedIsMain) {
        ARNote(query, @"The window with the keyboard is not a main window, so leave it be");
    }
    return focusedIsMain && ((!sameApp && !candidate.appRaisesOnFocus) || !wouldCoverOwnDialog);
}

ARRaiseDecision ARDecideRaise(ARRaiseQuery *query) {
    ARRaiseDecision decision = ARDecideCandidate(query);
    decision.needsRaise = ARDecideAgainstFocused(query, decision);
    return decision;
}

NSString *ARDecisionSummary(ARRaiseQuery *query, ARRaiseDecision decision, BOOL focusFirst) {
    if (!decision.needsRaise) { return @"Nothing to do"; }
    if (focusFirst) {
        return decision.appRaisesOnFocus ? @"Focus it, and it will raise itself"
                                         : @"Give it the keyboard where it is";
    }
    return @"Raise it";
}

//------------------------------------------- dialog buttons ------------------------------------------------

@implementation ARDialogButton
- (void)dealloc {
    if (_element) { CFRelease(_element); }
}
@end

BOOL ARDialogAimParse(NSString *text, ARDialogAim *aim) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"off": @(ARDialogAimOff), @"": @(ARDialogAimOff), @"false": @(ARDialogAimOff),
                  @"default": @(ARDialogAimDefault), @"true": @(ARDialogAimDefault),
                  @"cancel": @(ARDialogAimCancel),
                  @"nearest": @(ARDialogAimNearest)};
    }
    if (![text isKindOfClass: [NSString class]]) { return NO; }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString]];
    if (!found) { return NO; }
    if (aim) { *aim = (ARDialogAim) found.integerValue; }
    return YES;
}

NSString *ARDialogAimDescribe(ARDialogAim aim) {
    switch (aim) {
        case ARDialogAimDefault: return @"default";
        case ARDialogAimCancel: return @"cancel";
        case ARDialogAimNearest: return @"nearest";
        default: return @"off";
    }
}

static CGFloat ARDistanceToButton(ARDialogButton *button, CGPoint from) {
    CGPoint centre = CGPointMake(CGRectGetMidX(button.frame), CGRectGetMidY(button.frame));
    return hypot(centre.x - from.x, centre.y - from.y);
}

static NSInteger ARNearestButton(NSArray<ARDialogButton *> *buttons, CGPoint pointer,
                                 NSInteger except) {
    NSInteger best = -1;
    CGFloat shortest = 0;
    for (NSUInteger i = 0; i < buttons.count; i++) {
        if ((NSInteger) i == except || !buttons[i].enabled) { continue; }
        CGFloat distance = ARDistanceToButton(buttons[i], pointer);
        if (best < 0 || distance < shortest) { best = i; shortest = distance; }
    }
    return best;
}

static BOOL ARButtonIsDestructive(ARDialogButton *button, ARQuirks *quirks) {
    return ARTitleMatches(button.title, nil, quirks.destructiveButtons);
}

ARDialogTarget ARChooseDialogButton(NSArray<ARDialogButton *> *buttons, ARDialogAim aim,
                                    CGPoint pointer, ARQuirks *quirks) {
    ARDialogTarget target = {-1, NO};
    if (aim == ARDialogAimOff || !buttons.count) { return target; }

    NSInteger chosen = -1;
    switch (aim) {
        case ARDialogAimDefault:
            for (NSUInteger i = 0; i < buttons.count; i++) {
                if (buttons[i].isDefault && buttons[i].enabled) { chosen = i; break; }
            }
            // A dialog that names no default button and offers one way out has
            // only one place a click can land.
            if (chosen < 0 && buttons.count == 1 && buttons[0].enabled) { chosen = 0; }
            break;
        case ARDialogAimCancel:
            for (NSUInteger i = 0; i < buttons.count; i++) {
                if (buttons[i].isCancel && buttons[i].enabled) { chosen = i; break; }
            }
            break;
        case ARDialogAimNearest:
            chosen = ARNearestButton(buttons, pointer, -1);
            break;
        default:
            break;
    }
    if (chosen < 0) { return target; }

    // The one rule that overrides the setting. Parking the pointer over Delete
    // turns a stray click into lost work, so aim at the way out instead, and at
    // nothing at all when every way out is destructive.
    if (ARButtonIsDestructive(buttons[chosen], quirks)) {
        target.avoidedDestructive = YES;
        NSInteger safe = -1;
        for (NSUInteger i = 0; i < buttons.count; i++) {
            if ((NSInteger) i == chosen || !buttons[i].enabled) { continue; }
            if (ARButtonIsDestructive(buttons[i], quirks)) { continue; }
            // The cancel button is the safest of the safe ones.
            if (buttons[i].isCancel) { safe = i; break; }
            if (safe < 0) { safe = i; }
        }
        target.index = safe;
        return target;
    }

    target.index = chosen;
    return target;
}

ARCorrectedPoint ARCorrectMousePoint(CGPoint raw, CGPoint delta,
                                     BOOL hasScreen, CGRect screenFrame, CGFloat menuBarHeight) {
    ARCorrectedPoint result = {raw, ARCorrectionNone};
    result.point.x += delta.x > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
    result.point.y += delta.y > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
    if (!hasScreen) { return result; }

    CGFloat originX = screenFrame.origin.x;
    CGFloat originY = screenFrame.origin.y;
    CGFloat width = screenFrame.size.width;
    CGFloat height = screenFrame.size.height;

    // Within WINDOW_CORRECTION of a screen edge the correction would push the
    // point onto the neighbouring display, so clamp it just inside instead.
    if (raw.x > originX + width - WINDOW_CORRECTION) {
        result.point.x = originX + width - SCREEN_EDGE_CORRECTION;
        result.applied = (ARCorrection) (result.applied | ARCorrectionScreenEdge);
    } else if (raw.x < originX + WINDOW_CORRECTION - 1) {
        result.point.x = originX + SCREEN_EDGE_CORRECTION;
        result.applied = (ARCorrection) (result.applied | ARCorrectionScreenEdge);
    }

    if (raw.y > originY + height - WINDOW_CORRECTION) {
        result.point.y = originY + height - SCREEN_EDGE_CORRECTION;
        result.applied = (ARCorrection) (result.applied | ARCorrectionScreenEdge);
    } else if (result.point.y < originY + menuBarHeight + MENUBAR_CORRECTION) {
        // Keep windows that touch the menu bar from raising when the mouse
        // travels along it.
        result.point.y = originY;
        result.applied = (ARCorrection) (result.applied | ARCorrectionMenuBar);
    }

    return result;
}

ARDelayState ARResetDelay(void) {
    ARDelayState state = {0, 0};
    return state;
}

// delayTicks == 0: no delay running. == 1: delay elapsed, act now.
// raiseTimes > 0: keep acting on the following evaluations.
ARDelayStep ARAdvanceDelay(ARDelayState state, int delayCount) {
    ARDelayStep step = {NO, state};
    if (!step.state.delayTicks) { step.state.delayTicks = delayCount; }
    if (step.state.raiseTimes || step.state.delayTicks == 1) {
        step.state.delayTicks = 0;
        if (step.state.raiseTimes) { step.state.raiseTimes--; }
        else { step.state.raiseTimes = AR_RAISE_REPEATS; }
        step.act = YES;
    }
    return step;
}

//------------------------------------------------- intent -------------------------------------------------

// Named tunings. The speeds are in points per second: a deliberate move across a
// screen runs at a couple of thousand, a careful adjustment at a hundred or so.
ARIntentTuning ARTuningFor(AREagerness eagerness) {
    switch (eagerness) {
        case AREagernessInstant: return (ARIntentTuning) {1200, 0.00, 2};
        case AREagernessQuick:   return (ARIntentTuning) {600,  0.02, 2};
        case AREagernessRelaxed: return (ARIntentTuning) {90,   0.18, 3};
        default:                 return (ARIntentTuning) {260,  0.06, 2};
    }
}

BOOL AREagernessParse(NSString *text, AREagerness *eagerness) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"instant": @(AREagernessInstant), @"immediate": @(AREagernessInstant),
                  @"quick": @(AREagernessQuick), @"fast": @(AREagernessQuick),
                  @"normal": @(AREagernessNormal), @"default": @(AREagernessNormal),
                  @"relaxed": @(AREagernessRelaxed), @"slow": @(AREagernessRelaxed),
                  @"patient": @(AREagernessRelaxed)};
    }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString] ?: @""];
    if (!found) { return NO; }
    if (eagerness) { *eagerness = (AREagerness) found.integerValue; }
    return YES;
}

NSString *AREagernessDescribe(AREagerness eagerness) {
    switch (eagerness) {
        case AREagernessInstant: return @"instant";
        case AREagernessQuick: return @"quick";
        case AREagernessRelaxed: return @"relaxed";
        default: return @"normal";
    }
}

@implementation ARIntentReader {
    CGPoint _last;
    NSTimeInterval _lastTime;
    BOOL _started;
    CGFloat _speed;
    NSTimeInterval _slowSince;   // when the pointer last dropped below the threshold
    BOOL _settled;
}

- (instancetype)initWithTuning:(ARIntentTuning)tuning {
    if ((self = [super init])) {
        _tuning = tuning;
        [self reset];
    }
    return self;
}

- (void)reset {
    _started = NO;
    _speed = 0;
    _slowSince = 0;
    _settled = NO;
}

- (ARIntent)intent {
    return (ARIntent) {_speed, _settled, NO};
}

- (ARIntent)addPoint:(CGPoint)point atTime:(NSTimeInterval)time {
    if (!_started) {
        _started = YES;
        _last = point;
        _lastTime = time;
        // Nothing is known yet, so treat the first sample as standing still.
        _slowSince = time;
        _speed = 0;
        return [self stateAtTime: time];
    }

    CGFloat distance = hypot(point.x - _last.x, point.y - _last.y);
    NSTimeInterval elapsed = time - _lastTime;
    _last = point;
    _lastTime = time;

    // A pointer that moved a pixel or two, or not at all, is not travelling: a
    // shaky hand and a parked hand both mean it has arrived.
    if (distance <= _tuning.jitter || elapsed <= 0) {
        _speed = 0;
        if (_slowSince == 0) { _slowSince = time; }
        return [self stateAtTime: time];
    }

    CGFloat instant = distance / elapsed;
    if (instant > AR_TELEPORT_SPEED) {
        // The pointer was put here rather than moved here, by a warp or by
        // switching displays. Nothing was travelled over, so the journey starts
        // afresh from wherever it landed.
        _speed = 0;
        _slowSince = time;
        return [self stateAtTime: time];
    }
    // Smoothed, so one stray sample neither starts nor stops a journey.
    _speed = _speed * 0.6 + instant * 0.4;

    if (_speed > _tuning.settleSpeed) {
        _slowSince = 0;
        _settled = NO;
    } else if (_slowSince == 0) {
        _slowSince = time;
    }
    return [self stateAtTime: time];
}

- (ARIntent)settleAtTime:(NSTimeInterval)time {
    if (!_started) {
        BOOL arrived = !_settled;
        _settled = YES;
        return (ARIntent) {0, YES, arrived};
    }
    // No events since the last one means the pointer has been still since then,
    // whatever speed that last sample happened to report.
    _speed = 0;
    if (_slowSince == 0) { _slowSince = _lastTime; }
    return [self stateAtTime: time];
}

- (ARIntent)stateAtTime:(NSTimeInterval)time {
    BOOL slowEnough = _slowSince != 0 && time - _slowSince >= _tuning.confirm;
    BOOL arrived = slowEnough && !_settled;
    _settled = slowEnough;
    return (ARIntent) {_speed, _settled, arrived};
}

@end

//--------------------------------------------- app policies -------------------------------------------------

BOOL ARAppPolicyParse(NSString *text, ARAppPolicy *policy) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"default": @(ARAppPolicyDefault), @"": @(ARAppPolicyDefault),
                  @"raise": @(ARAppPolicyRaise),
                  @"focus": @(ARAppPolicyFocus),
                  @"quiet": @(ARAppPolicyQuiet),
                  @"ignore": @(ARAppPolicyIgnore), @"leave": @(ARAppPolicyIgnore),
                  @"keepfocus": @(ARAppPolicyKeepFocus), @"keep": @(ARAppPolicyKeepFocus)};
    }
    if (![text isKindOfClass: [NSString class]]) { return NO; }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString]];
    if (!found) { return NO; }
    if (policy) { *policy = (ARAppPolicy) found.integerValue; }
    return YES;
}

NSString *ARAppPolicyDescribe(ARAppPolicy policy) {
    switch (policy) {
        case ARAppPolicyRaise: return @"raise";
        case ARAppPolicyFocus: return @"focus";
        case ARAppPolicyQuiet: return @"quiet";
        case ARAppPolicyIgnore: return @"ignore";
        case ARAppPolicyKeepFocus: return @"keepFocus";
        default: return @"default";
    }
}

NSArray<NSString *> *ARAppPolicyNames(void) {
    return @[@"Follow the general setting", @"Always raise", @"Focus without raising",
             @"Focus quietly", @"Leave it alone", @"Never lose the keyboard"];
}
