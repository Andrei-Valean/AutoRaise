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

ARRaiseDecision ARDecideCandidate(ARRaiseQuery *query) {
    ARRaiseDecision decision = {NO, NO};
    ARWindow *mouse = query.mouseWindow;
    ARQuirks *quirks = query.quirks;

    // AutoRaise's own windows, the focus ring above all, are not candidates.
    if (query.ownPid && mouse.pid == query.ownPid) { return decision; }

    BOOL needsRaise = !query.invertIgnoreApps && query.mouseWindowPresent;

    if (needsRaise && ARTitleMatches(mouse.title, quirks.titlesNeedingMainWindowCheck, nil)) {
        needsRaise = ARIsMainWindow(mouse, quirks);
    } else if (needsRaise && ARTitleMatches(mouse.title, quirks.ignoreTitles, query.ignoreTitles)) {
        needsRaise = NO;
    } else if (query.mouseWindowPresent) {
        if (ARMatchesApp(mouse, query.ignoreApps) || ARMatchesApp(mouse, quirks.ignoreApps)) {
            needsRaise = query.invertIgnoreApps;
        }
        decision.appRaisesOnFocus = ARMatchesApp(mouse, quirks.appsRaisingOnFocus);
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
        return !query.frontmostHasMainWindow;
    }

    if (mouse.windowId == focused.windowId) { return NO; }

    // A password prompt or another system dialog keeps the keyboard until it is
    // dealt with. Hovering past it must not take the focus away.
    if (focused.isSystemDialog) { return NO; }

    // Nor must it close a panel. A colour picker, an inspector or a find bar
    // disappears as soon as its application stops being frontmost, so drifting
    // off one of them would dismiss the thing being used.
    if (query.frontmostHasPanel && mouse.pid != focused.pid) { return NO; }

    // The focused window sitting inside the hovered one is what a dialog
    // belonging to it looks like, and raising the parent over its own dialog
    // would be wrong. Across applications the same geometry means nothing: a
    // small window parked on top of a big one, a calculator over an editor,
    // must not make the whole window underneath unhoverable.
    BOOL sameApp = mouse.pid == focused.pid;
    BOOL wouldCoverOwnDialog = sameApp && ARWindowContainedWithin(focused, mouse);

    if (!query.focusFirst) { return !wouldCoverOwnDialog; }
    return ARIsMainWindow(focused, query.quirks) &&
           ((!sameApp && !candidate.appRaisesOnFocus) || !wouldCoverOwnDialog);
}

ARRaiseDecision ARDecideRaise(ARRaiseQuery *query) {
    ARRaiseDecision decision = ARDecideCandidate(query);
    decision.needsRaise = ARDecideAgainstFocused(query, decision);
    return decision;
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
