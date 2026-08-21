/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Tests for the parts of AutoRaise that decide things: which window counts as
 * raisable, how the mouse position is corrected, how settings are parsed. None
 * of it touches the accessibility API, so this runs anywhere, including in CI
 * with no desktop and no permission granted.
 *
 * Run with: make test
 */

#import <Foundation/Foundation.h>

#import "Config.h"
#import "Policy.h"
#import "Quirks.h"
#import "Stats.h"

static int checks = 0;
static int failures = 0;
static const char *currentCase = "";

#define CASE(name) currentCase = name
#define CHECK(expression) do { \
    checks++; \
    if (!(expression)) { \
        failures++; \
        fprintf(stderr, "FAIL %s\n  %s:%d: %s\n", currentCase, __FILE__, __LINE__, #expression); \
    } \
} while (0)

#define CHECK_EQ_INT(actual, expected) do { \
    checks++; \
    long long a = (long long) (actual), e = (long long) (expected); \
    if (a != e) { \
        failures++; \
        fprintf(stderr, "FAIL %s\n  %s:%d: %s was %lld, expected %lld\n", \
                currentCase, __FILE__, __LINE__, #actual, a, e); \
    } \
} while (0)

#define CHECK_EQ_STR(actual, expected) do { \
    checks++; \
    NSString *a = (actual), *e = (expected); \
    if (a != e && ![a isEqual: e]) { \
        failures++; \
        fprintf(stderr, "FAIL %s\n  %s:%d: %s was \"%s\", expected \"%s\"\n", \
                currentCase, __FILE__, __LINE__, #actual, \
                a ? a.UTF8String : "(nil)", e ? e.UTF8String : "(nil)"); \
    } \
} while (0)

//--------------------------------------------- fixtures ---------------------------------------------------

static ARWindow *makeWindow(NSString *title, NSString *appName, NSString *bundleId) {
    ARWindow *window = [[ARWindow alloc] init];
    window.known = YES;
    window.pid = 100;
    window.windowId = 1;
    window.title = title;
    window.appName = appName;
    window.bundleId = bundleId;
    window.isMain = YES;
    window.hasFrame = YES;
    window.frame = CGRectMake(100, 100, 400, 300);
    return window;
}

// A window filling a display that has a 25 pixel menu bar.
static ARWindow *makeFullScreenWindow(void) {
    ARWindow *window = makeWindow(nil, @"Preview", @"com.apple.Preview");
    window.isMain = NO;
    window.frame = CGRectMake(0, 25, 1920, 1055);
    window.hasScreen = YES;
    window.screenFrame = CGRectMake(0, 0, 1920, 1080);
    window.menuBarHeight = 25;
    return window;
}

//----------------------------------------------- matching -------------------------------------------------

static void testMatching(void) {
    ARWindow *window = makeWindow(@"notes.txt", @"TextEdit", @"com.apple.TextEdit");

    CASE("app matches by localized name");
    CHECK(ARMatchesApp(window, @[@"TextEdit"]));

    CASE("app matches by bundle identifier, any case");
    CHECK(ARMatchesApp(window, @[@"com.apple.textedit"]));
    CHECK(ARMatchesApp(window, @[@"Safari", @"com.apple.TextEdit"]));

    CASE("app does not match something else");
    CHECK(!ARMatchesApp(window, @[@"Safari"]));
    CHECK(!ARMatchesApp(window, @[]));
    CHECK(!ARMatchesApp(window, nil));

    CASE("an untitled window matches the empty title");
    CHECK(ARTitleMatches(nil, @[@""], nil));
    CHECK(!ARTitleMatches(nil, @[@"Untitled"], nil));

    CASE("titles match exactly or by pattern");
    CHECK(ARTitleMatches(@"Bartender Bar", @[@"Bartender Bar"], nil));
    CHECK(ARTitleMatches(@"chat | Microsoft Teams", nil, @[@"\\| Microsoft Teams"]));
    CHECK(ARTitleMatches(@"window", nil, @[@"^window$"]));
    CHECK(!ARTitleMatches(@"my window", nil, @[@"^window$"]));
    CHECK(!ARTitleMatches(@"anything", @[@"other"], @[@"^nope$"]));

    CASE("progressive web apps are recognised by bundle identifier");
    CHECK(ARIsPWA(@"com.google.Chrome.app.abcdefghijk", @[@"Chrome"]));
    CHECK(ARIsPWA(@"com.pake.myapp", @[@"Chrome"]));
    CHECK(!ARIsPWA(@"com.myapp.pake", @[@"Chrome"]));
    CHECK(!ARIsPWA(@"com.google.Chrome", @[@"Chrome"]));
    CHECK(!ARIsPWA(@"com.apple.Safari", @[@"Chrome"]));
    CHECK(!ARIsPWA(nil, @[@"Chrome"]));
}

//---------------------------------------------- main window -----------------------------------------------

static void testMainWindow(void) {
    ARQuirks *quirks = ARQuirksDefaults();

    CASE("a titled main window is a main window");
    CHECK(ARIsMainWindow(makeWindow(@"notes.txt", @"TextEdit", @"com.apple.TextEdit"), quirks));

    CASE("an untitled window is not, unless the app is known for it");
    CHECK(!ARIsMainWindow(makeWindow(nil, @"Xcode", @"com.apple.dt.Xcode"), quirks));
    CHECK(ARIsMainWindow(makeWindow(nil, @"System Settings", @"com.apple.systempreferences"), quirks));

    CASE("Finder's untitled desktop window still counts");
    CHECK(ARIsMainWindow(makeWindow(nil, @"Finder", @"com.apple.finder"), quirks));

    CASE("Finder counts even when its name is localized away");
    ARWindow *dutchFinder = makeWindow(nil, @"Zoeker", @"com.apple.finder");
    CHECK(ARIsMainWindow(dutchFinder, quirks));

    CASE("a dialog is never a main window");
    ARWindow *dialog = makeWindow(@"Save", @"TextEdit", @"com.apple.TextEdit");
    dialog.isDialog = YES;
    CHECK(!ARIsMainWindow(dialog, quirks));

    CASE("an untitled web app window counts");
    CHECK(ARIsMainWindow(makeWindow(nil, @"Notion", @"com.google.Chrome.app.xyzzy1234"), quirks));

    CASE("a full screen window counts even when it is not main");
    ARWindow *fullScreen = makeFullScreenWindow();
    CHECK(ARIsFullScreen(fullScreen));
    CHECK(ARIsMainWindow(fullScreen, quirks));

    CASE("one pixel off is not full screen");
    ARWindow *nearly = makeFullScreenWindow();
    nearly.frame = CGRectMake(0, 25, 1920, 1054);
    CHECK(!ARIsFullScreen(nearly));

    CASE("the Finder desktop is not treated as full screen");
    ARWindow *desktop = makeFullScreenWindow();
    desktop.appName = @"Finder";
    desktop.bundleId = @"com.apple.finder";
    desktop.isMain = NO;
    CHECK(!ARIsMainWindow(desktop, quirks));

    CASE("containment needs a strictly smaller rectangle");
    CHECK(ARContainedWithin(CGRectMake(10, 10, 10, 10), CGRectMake(0, 0, 100, 100)));
    CHECK(!ARContainedWithin(CGRectMake(0, 0, 100, 100), CGRectMake(0, 0, 100, 100)));
    CHECK(!ARContainedWithin(CGRectMake(50, 50, 100, 100), CGRectMake(0, 0, 100, 100)));
}

//----------------------------------------------- decisions ------------------------------------------------

static ARRaiseQuery *makeQuery(void) {
    ARRaiseQuery *query = [[ARRaiseQuery alloc] init];
    query.quirks = ARQuirksDefaults();
    query.mouseWindowPresent = YES;
    query.mouseWindow = makeWindow(@"hovered", @"TextEdit", @"com.apple.TextEdit");
    query.mouseWindow.windowId = 2;

    ARWindow *focused = makeWindow(@"focused", @"Safari", @"com.apple.Safari");
    focused.windowId = 1;
    focused.pid = 200;
    focused.frame = CGRectMake(600, 100, 400, 300);
    query.focusedWindow = focused;
    return query;
}

static void testDecisions(void) {
    CASE("hovering another window raises it");
    CHECK(ARDecideRaise(makeQuery()).needsRaise);

    CASE("hovering the focused window changes nothing");
    ARRaiseQuery *same = makeQuery();
    same.mouseWindow.windowId = same.focusedWindow.windowId;
    CHECK(!ARDecideRaise(same).needsRaise);

    CASE("a destroyed window is not raised");
    ARRaiseQuery *destroyed = makeQuery();
    destroyed.mouseWindowPresent = NO;
    CHECK(!ARDecideRaise(destroyed).needsRaise);

    CASE("an ignored app is left alone, by name or bundle identifier");
    ARRaiseQuery *ignoredByName = makeQuery();
    ignoredByName.ignoreApps = @[@"TextEdit"];
    CHECK(!ARDecideRaise(ignoredByName).needsRaise);
    ARRaiseQuery *ignoredById = makeQuery();
    ignoredById.ignoreApps = @[@"com.apple.TextEdit"];
    CHECK(!ARDecideRaise(ignoredById).needsRaise);

    CASE("invertIgnoreApps turns the list into an allow list");
    ARRaiseQuery *inverted = makeQuery();
    inverted.invertIgnoreApps = YES;
    inverted.ignoreApps = @[@"TextEdit"];
    CHECK(ARDecideRaise(inverted).needsRaise);
    ARRaiseQuery *notListed = makeQuery();
    notListed.invertIgnoreApps = YES;
    notListed.ignoreApps = @[@"Safari"];
    CHECK(!ARDecideRaise(notListed).needsRaise);

    CASE("an ignored title is left alone");
    ARRaiseQuery *ignoredTitle = makeQuery();
    ignoredTitle.ignoreTitles = @[@"^hovered$"];
    CHECK(!ARDecideRaise(ignoredTitle).needsRaise);

    CASE("built-in ignored titles still apply");
    ARRaiseQuery *bartender = makeQuery();
    bartender.mouseWindow.title = @"Bartender Bar";
    CHECK(!ARDecideRaise(bartender).needsRaise);

    CASE("a dialog of the hovered window keeps the focus");
    ARRaiseQuery *contained = makeQuery();
    contained.focusedWindow.pid = contained.mouseWindow.pid;          // same app
    contained.focusedWindow.frame = CGRectMake(150, 150, 100, 100);   // inside the hovered window
    CHECK(!ARDecideRaise(contained).needsRaise);

    CASE("but another app's small window on top does not block the one underneath");
    ARRaiseQuery *foreign = makeQuery();
    foreign.focusedWindow.frame = CGRectMake(150, 150, 100, 100);     // inside, different app
    CHECK(ARDecideRaise(foreign).needsRaise);
    ARRaiseQuery *foreignFocusFirst = makeQuery();
    foreignFocusFirst.focusFirst = YES;
    foreignFocusFirst.focusedWindow.frame = CGRectMake(150, 150, 100, 100);
    CHECK(ARDecideRaise(foreignFocusFirst).needsRaise);

    CASE("a system dialog never loses the keyboard");
    ARRaiseQuery *prompt = makeQuery();
    prompt.focusedWindow.isSystemDialog = YES;
    CHECK(!ARDecideRaise(prompt).needsRaise);
    prompt.focusFirst = YES;
    CHECK(!ARDecideRaise(prompt).needsRaise);

    CASE("no focused window and no main window means raise");
    ARRaiseQuery *nothingFocused = makeQuery();
    nothingFocused.focusedWindow = [[ARWindow alloc] init];
    nothingFocused.frontmostHasMainWindow = NO;
    CHECK(ARDecideRaise(nothingFocused).needsRaise);

    CASE("an app between windows is left alone");
    ARRaiseQuery *transitioning = makeQuery();
    transitioning.focusedWindow = [[ARWindow alloc] init];
    transitioning.frontmostHasMainWindow = YES;
    CHECK(!ARDecideRaise(transitioning).needsRaise);

    CASE("focus first needs the focused window to be a real main window");
    ARRaiseQuery *focusFirst = makeQuery();
    focusFirst.focusFirst = YES;
    CHECK(ARDecideRaise(focusFirst).needsRaise);
    ARRaiseQuery *focusedIsDialog = makeQuery();
    focusedIsDialog.focusFirst = YES;
    focusedIsDialog.focusedWindow.isDialog = YES;
    CHECK(!ARDecideRaise(focusedIsDialog).needsRaise);

    CASE("apps that raise themselves on focus are skipped within one process");
    ARRaiseQuery *sameProcess = makeQuery();
    sameProcess.focusFirst = YES;
    sameProcess.mouseWindow.appName = @"IntelliJ IDEA";
    sameProcess.mouseWindow.pid = sameProcess.focusedWindow.pid;
    ARRaiseDecision decision = ARDecideCandidate(sameProcess);
    CHECK(decision.appRaisesOnFocus);
    // Same process, so the raise only happens when the focused window is not
    // nested inside the hovered one.
    CHECK(ARDecideAgainstFocused(sameProcess, decision));
    sameProcess.focusedWindow.frame = CGRectMake(150, 150, 100, 100);
    CHECK(!ARDecideAgainstFocused(sameProcess, decision));

    CASE("AutoRaise never raises its own windows");
    ARRaiseQuery *own = makeQuery();
    own.ownPid = own.mouseWindow.pid;
    CHECK(!ARDecideRaise(own).needsRaise);

    CASE("the accessibility helper window is always ignored");
    ARRaiseQuery *assistive = makeQuery();
    assistive.mouseWindow.appName = @"AssistiveControl";
    CHECK(!ARDecideRaise(assistive).needsRaise);
}

//---------------------------------------- mouse point correction ------------------------------------------

static void testCorrections(void) {
    CGRect screen = CGRectMake(0, 0, 1920, 1080);

    CASE("moving right and down pushes the point past the transparent border");
    ARCorrectedPoint corrected = ARCorrectMousePoint(CGPointMake(500, 500),
        CGPointMake(4, 4), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.x, 503);
    CHECK_EQ_INT(corrected.point.y, 503);
    CHECK_EQ_INT(corrected.applied, ARCorrectionNone);

    CASE("moving left and up pushes it the other way");
    corrected = ARCorrectMousePoint(CGPointMake(500, 500), CGPointMake(-4, -4), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.x, 497);
    CHECK_EQ_INT(corrected.point.y, 497);

    CASE("the right edge is clamped instead of pushed onto the next display");
    corrected = ARCorrectMousePoint(CGPointMake(1919, 500), CGPointMake(4, 0), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.x, 1919);
    CHECK(corrected.applied & ARCorrectionScreenEdge);

    CASE("so is the left edge");
    corrected = ARCorrectMousePoint(CGPointMake(1, 500), CGPointMake(-4, 0), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.x, 1);
    CHECK(corrected.applied & ARCorrectionScreenEdge);

    CASE("near the menu bar the point snaps to the top of the screen");
    corrected = ARCorrectMousePoint(CGPointMake(500, 28), CGPointMake(0, -4), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.y, 0);
    CHECK(corrected.applied & ARCorrectionMenuBar);

    CASE("well below the menu bar it does not");
    corrected = ARCorrectMousePoint(CGPointMake(500, 200), CGPointMake(0, -4), YES, screen, 25);
    CHECK_EQ_INT(corrected.point.y, 197);
    CHECK_EQ_INT(corrected.applied, ARCorrectionNone);

    CASE("a secondary display above the primary one keeps its own origin");
    CGRect above = CGRectMake(0, -1080, 1920, 1080);
    corrected = ARCorrectMousePoint(CGPointMake(500, -1078), CGPointMake(0, -4), YES, above, 0);
    CHECK_EQ_INT(corrected.point.y, -1080);
    CHECK(corrected.applied & ARCorrectionMenuBar);

    CASE("without a display only the border correction applies");
    corrected = ARCorrectMousePoint(CGPointMake(9000, 9000), CGPointMake(4, 4), NO, CGRectZero, 0);
    CHECK_EQ_INT(corrected.point.x, 9003);
    CHECK_EQ_INT(corrected.applied, ARCorrectionNone);
}

//------------------------------------------------- delay --------------------------------------------------

static void testDelay(void) {
    CASE("delay 1 acts immediately and then repeats");
    ARDelayState state = ARResetDelay();
    ARDelayStep step = ARAdvanceDelay(state, 1);
    CHECK(step.act);
    CHECK_EQ_INT(step.state.raiseTimes, AR_RAISE_REPEATS);

    int repeats = 0;
    state = step.state;
    while (state.raiseTimes) {
        step = ARAdvanceDelay(state, 1);
        state = step.state;
        if (step.act) { repeats++; }
    }
    CHECK_EQ_INT(repeats, AR_RAISE_REPEATS);

    CASE("delay 3 waits two evaluations");
    state = ARResetDelay();
    step = ARAdvanceDelay(state, 3);
    CHECK(!step.act);
    CHECK_EQ_INT(step.state.delayTicks, 3);

    // The countdown itself happens in the caller, once per evaluation.
    state = step.state;
    state.delayTicks--;
    step = ARAdvanceDelay(state, 3);
    CHECK(!step.act);
    state = step.state;
    state.delayTicks--;
    step = ARAdvanceDelay(state, 3);
    CHECK(step.act);

    CASE("delay 0 never acts");
    state = ARResetDelay();
    step = ARAdvanceDelay(state, 0);
    CHECK(!step.act);
}

//------------------------------------------------ settings ------------------------------------------------

static void testConfigParsing(void) {
    CASE("a list splits on commas and trims when asked");
    NSArray *apps = ARSplitList(@"IntelliJ IDEA, WebStorm", YES);
    CHECK_EQ_INT(apps.count, 2);
    CHECK_EQ_STR(apps[1], @"WebStorm");

    CASE("an escaped comma stays part of the entry");
    NSArray *titles = ARSplitList(@"Hello\\, World,other", NO);
    CHECK_EQ_INT(titles.count, 2);
    CHECK_EQ_STR(titles[0], @"Hello, World");
    CHECK_EQ_STR(titles[1], @"other");

    CASE("regular expression backslashes survive");
    NSArray *patterns = ARSplitList(@"\\s\\| Microsoft Teams,^window$", NO);
    CHECK_EQ_INT(patterns.count, 2);
    CHECK_EQ_STR(patterns[0], @"\\s\\| Microsoft Teams");

    CASE("a setting containing = is not cut in half");
    NSMutableArray *warnings = [NSMutableArray array];
    NSDictionary *values = ARConfigParseFile(@"ignoreTitles=^a=b$\n", warnings);
    CHECK_EQ_STR(values[@"ignoreTitles"], @"^a=b$");
    CHECK_EQ_INT(warnings.count, 0);

    CASE("only the surrounding quotes are removed");
    values = ARConfigParseFile(@"ignoreApps=\"a \\\"quoted\\\" app\"\n", [NSMutableArray array]);
    CHECK_EQ_STR(values[@"ignoreApps"], @"a \\\"quoted\\\" app");

    CASE("comments and blank lines are skipped");
    warnings = [NSMutableArray array];
    values = ARConfigParseFile(@"# a comment\n\n  delay = 2  \n", warnings);
    CHECK_EQ_STR(values[@"delay"], @"2");
    CHECK_EQ_INT(warnings.count, 0);

    CASE("a typo is reported instead of silently ignored");
    warnings = [NSMutableArray array];
    values = ARConfigParseFile(@"dealy=2\nnonsense\n", warnings);
    CHECK_EQ_INT(values.count, 0);
    CHECK_EQ_INT(warnings.count, 2);

    CASE("arguments accept both spellings");
    const char *argv[] = {"AutoRaise", "-delay", "3", "-verbose=true"};
    warnings = [NSMutableArray array];
    values = ARConfigParseArguments(4, argv, warnings);
    CHECK_EQ_STR(values[@"delay"], @"3");
    CHECK_EQ_STR(values[@"verbose"], @"true");
    CHECK_EQ_INT(warnings.count, 0);

    CASE("an unknown argument is reported and its value skipped");
    const char *unknown[] = {"AutoRaise", "-nope", "1", "-delay", "2"};
    warnings = [NSMutableArray array];
    values = ARConfigParseArguments(5, unknown, warnings);
    CHECK_EQ_INT(warnings.count, 1);
    CHECK_EQ_STR(values[@"delay"], @"2");
}

static void testConfigValues(void) {
    CASE("nothing configured means raise, at a normal eagerness");
    ARConfig *config = ARConfigFromValues(@{}, nil);
    CHECK_EQ_INT(config.mode, ARHoverModeRaise);
    CHECK_EQ_INT(config.eagerness, AREagernessNormal);
    CHECK(config.raises);
    CHECK(!config.focusFirst);

    CASE("each mode is spellable and derives what the program needs");
    config = ARConfigFromValues(@{@"mode": @"focus"}, nil);
    CHECK(config.focusFirst);
    CHECK(!config.raises);
    config = ARConfigFromValues(@{@"mode": @"focusThenRaise"}, nil);
    CHECK(config.focusFirst);
    CHECK(config.raises);
    CHECK_EQ_INT(config.raiseAfterMillis, 400);
    config = ARConfigFromValues(@{@"mode": @"both", @"raiseAfter": @"1200"}, nil);
    CHECK_EQ_INT(config.mode, ARHoverModeFocusThenRaise);
    CHECK_EQ_INT(config.raiseAfterMillis, 1200);
    ARConfig *bogusHover = ARConfigFromValues(@{@"mode": @"levitate"}, nil);
    CHECK_EQ_INT(bogusHover.mode, ARHoverModeRaise);
    CHECK_EQ_INT(bogusHover.warnings.count, 1);

    CASE("a mode survives a round trip");
    for (NSString *name in @[@"raise", @"focusThenRaise", @"focus"]) {
        ARHoverMode mode = ARHoverModeRaise;
        CHECK(ARHoverModeParse(name, &mode));
        CHECK_EQ_STR(ARHoverModeDescribe(mode), name);
    }

    CASE("eagerness picks the tuning the pointer is read against");
    config = ARConfigFromValues(@{@"eagerness": @"relaxed"}, nil);
    CHECK_EQ_INT(config.eagerness, AREagernessRelaxed);
    CHECK(config.tuning.settleSpeed < ARTuningFor(AREagernessNormal).settleSpeed);
    CHECK(config.tuning.confirm > ARTuningFor(AREagernessNormal).confirm);
    ARConfig *bogusEager = ARConfigFromValues(@{@"eagerness": @"whenever"}, nil);
    CHECK_EQ_INT(bogusEager.eagerness, AREagernessNormal);
    CHECK_EQ_INT(bogusEager.warnings.count, 1);

    CASE("a settings file written for the old timings still says what it meant");
    // Focus only: the old way to say it was a raise delay of zero.
    ARConfig *old = ARConfigFromValues(@{@"delay": @"0", @"focusDelay": @"1"}, nil);
    CHECK_EQ_INT(old.mode, ARHoverModeFocus);
    CHECK_EQ_INT(old.eagerness, AREagernessInstant);
    CHECK_EQ_INT(old.warnings.count, 1);       // and it says so, once

    // Focus, then raise after ten polling intervals of fifty milliseconds.
    old = ARConfigFromValues(@{@"focusDelay": @"2", @"delay": @"11", @"pollMillis": @"50"}, nil);
    CHECK_EQ_INT(old.mode, ARHoverModeFocusThenRaise);
    CHECK_EQ_INT(old.raiseAfterMillis, 500);
    CHECK_EQ_INT(old.eagerness, AREagernessQuick);   // it waited one interval

    // A long raise delay was a patient person.
    old = ARConfigFromValues(@{@"delay": @"8", @"pollMillis": @"50"}, nil);
    CHECK_EQ_INT(old.mode, ARHoverModeRaise);
    CHECK_EQ_INT(old.eagerness, AREagernessRelaxed);

    // And not waiting for the pointer to stop was an impatient one.
    old = ARConfigFromValues(@{@"delay": @"4", @"requireMouseStop": @"false"}, nil);
    CHECK_EQ_INT(old.eagerness, AREagernessInstant);

    CASE("a new setting beside an old one wins, without a fight");
    old = ARConfigFromValues(@{@"delay": @"0", @"focusDelay": @"1", @"mode": @"raise",
                               @"eagerness": @"relaxed"}, nil);
    CHECK_EQ_INT(old.mode, ARHoverModeRaise);
    CHECK_EQ_INT(old.eagerness, AREagernessRelaxed);

    CASE("warping needs both factors");
    CHECK(!ARConfigFromValues(@{@"warpX": @"0.5"}, nil).warpMouse);
    CHECK(ARConfigFromValues(@{@"warpX": @"0.5", @"warpY": @"0.1"}, nil).warpMouse);
    CHECK(!ARConfigFromValues(@{@"warpX": @"2", @"warpY": @"0.1"}, nil).warpMouse);

    CASE("the disable key accepts the documented names");
    CHECK_EQ_INT(ARConfigFromValues(@{@"disableKey": @"option"}, nil).disableKey, kCGEventFlagMaskAlternate);
    CHECK_EQ_INT(ARConfigFromValues(@{@"disableKey": @"disabled"}, nil).disableKey, 0);
    ARConfig *bogus = ARConfigFromValues(@{@"disableKey": @"banana"}, nil);
    CHECK_EQ_INT(bogus.disableKey, 0);
    CHECK_EQ_INT(bogus.warnings.count, 1);

    CASE("self raising apps are focused normally unless asked otherwise");
    ARConfig *raising = ARConfigFromValues(@{}, nil);
    CHECK_EQ_INT(raising.selfRaisingApps, ARSelfRaisingFocus);
    CHECK_EQ_INT(ARConfigFromValues(@{@"selfRaisingApps": @"quiet"}, nil).selfRaisingApps,
                 ARSelfRaisingQuiet);
    CHECK_EQ_INT(ARConfigFromValues(@{@"selfRaisingApps": @" SKIP "}, nil).selfRaisingApps,
                 ARSelfRaisingSkip);
    ARConfig *bogusMode = ARConfigFromValues(@{@"selfRaisingApps": @"loud"}, nil);
    CHECK_EQ_INT(bogusMode.selfRaisingApps, ARSelfRaisingFocus);
    CHECK_EQ_INT(bogusMode.warnings.count, 1);

    CASE("that mode survives a round trip");
    for (NSString *name in @[@"focus", @"quiet", @"skip"]) {
        ARSelfRaisingApps mode = ARSelfRaisingFocus;
        CHECK(ARSelfRaisingParse(name, &mode));
        CHECK_EQ_STR(ARSelfRaisingDescribe(mode), name);
    }

    CASE("everything that used to be a compile time flag has a default");
    config = ARConfigFromValues(@{}, nil);
    CHECK(!config.legacyActivation);
    CHECK(config.windowServerHitTest);
    CHECK(config.menuBarIcon);
    CHECK(config.liveReload);
    CHECK_EQ_INT(config.selfRaisingApps, ARSelfRaisingFocus);
}

//------------------------------------------------- quirks -------------------------------------------------

static void testQuirks(void) {
    ARQuirks *defaults = ARQuirksDefaults();

    CASE("the built-in quirks are populated");
    CHECK(defaults.pwaBrowsers.count > 0);
    CHECK([defaults.ignoreApps containsObject: @"AssistiveControl"]);
    CHECK([defaults.finderApps containsObject: @"com.apple.finder"]);

    CASE("a user file adds to the defaults");
    NSError *error = nil;
    ARQuirks *merged = ARQuirksApplyOverrides(defaults, @{@"appsRaisingOnFocus": @[@"Zed"]}, &error);
    CHECK(error == nil);
    CHECK([merged.appsRaisingOnFocus containsObject: @"Zed"]);
    CHECK([merged.appsRaisingOnFocus containsObject: @"PyCharm"]);

    CASE("replaceDefaults makes the file authoritative");
    error = nil;
    merged = ARQuirksApplyOverrides(defaults,
        @{@"replaceDefaults": @YES, @"appsRaisingOnFocus": @[@"Zed"]}, &error);
    CHECK(error == nil);
    CHECK_EQ_INT(merged.appsRaisingOnFocus.count, 1);
    CHECK_EQ_INT(merged.pwaBrowsers.count, 0);

    CASE("a misspelled key is reported and the defaults kept");
    error = nil;
    merged = ARQuirksApplyOverrides(defaults, @{@"pwaBrowser": @[@"Chrome"]}, &error);
    CHECK(error != nil);
    CHECK_EQ_INT(merged.pwaBrowsers.count, defaults.pwaBrowsers.count);

    CASE("so is a value of the wrong shape");
    error = nil;
    merged = ARQuirksApplyOverrides(defaults, @{@"pwaBrowsers": @"Chrome"}, &error);
    CHECK(error != nil);
    error = nil;
    merged = ARQuirksApplyOverrides(defaults, @{@"pwaBrowsers": @[@3]}, &error);
    CHECK(error != nil);

    CASE("a // key is a comment, not an error");
    error = nil;
    merged = ARQuirksApplyOverrides(defaults, @{@"// note": @"anything", @"ignoreApps": @[@"Zed"]}, &error);
    CHECK(error == nil);
    CHECK([merged.ignoreApps containsObject: @"Zed"]);

    CASE("the defaults round trip through JSON");
    NSString *json = ARQuirksJSON(defaults);
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:
        [json dataUsingEncoding: NSUTF8StringEncoding] options: 0 error: nil];
    CHECK(parsed != nil);
    error = nil;
    ARQuirks *roundTripped = ARQuirksApplyOverrides(ARQuirksDefaults(),
        [parsed mutableCopy], &error);
    CHECK(error == nil);
    CHECK_EQ_INT(roundTripped.pwaBrowsers.count, defaults.pwaBrowsers.count);
}

//------------------------------------------------- colours ------------------------------------------------

static void testColors(void) {
    BOOL ok = NO;

    CASE("a hex colour parses, with or without the hash");
    ARColor color = ARColorParse(@"#0A84FF", &ok);
    CHECK(ok);
    CHECK(!color.followsAccent);
    CHECK_EQ_INT(round(color.red * 255), 10);
    CHECK_EQ_INT(round(color.green * 255), 132);
    CHECK_EQ_INT(round(color.blue * 255), 255);
    CHECK_EQ_INT(round(color.alpha * 255), 255);
    CHECK(!ARColorParse(@"0a84ff", &ok).followsAccent);
    CHECK(ok);

    CASE("three digits expand, and eight carry alpha");
    color = ARColorParse(@"#f0c", &ok);
    CHECK(ok);
    CHECK_EQ_INT(round(color.red * 255), 255);
    CHECK_EQ_INT(round(color.green * 255), 0);
    CHECK_EQ_INT(round(color.blue * 255), 204);
    color = ARColorParse(@"#0A84FF80", &ok);
    CHECK(ok);
    CHECK_EQ_INT(round(color.alpha * 255), 128);

    CASE("nothing, or the word accent, follows the system");
    CHECK(ARColorParse(nil, &ok).followsAccent);
    CHECK(ok);
    CHECK(ARColorParse(@"accent", &ok).followsAccent);
    CHECK(ok);
    CHECK(ARColorParse(@"  ACCENT ", &ok).followsAccent);
    CHECK(ok);

    CASE("nonsense is reported and falls back to the accent colour");
    CHECK(ARColorParse(@"banana", &ok).followsAccent);
    CHECK(!ok);
    CHECK(ARColorParse(@"#12345", &ok).followsAccent);
    CHECK(!ok);

    CASE("a colour survives a round trip");
    CHECK_EQ_STR(ARColorDescribe(ARColorParse(@"#0a84ff", NULL)), @"#0A84FF");
    CHECK_EQ_STR(ARColorDescribe(ARColorParse(@"accent", NULL)), @"accent");
    CHECK_EQ_STR(ARColorDescribe(ARColorParse(@"#0A84FF80", NULL)), @"#0A84FF80");

    CASE("the settings file reports a bad colour once");
    ARConfig *config = ARConfigFromValues(@{@"focusRingColor": @"nope"}, nil);
    CHECK(config.focusRingColor.followsAccent);
    CHECK_EQ_INT(config.warnings.count, 1);
    config = ARConfigFromValues(@{@"focusRingColor": @"#123456"}, nil);
    CHECK(!config.focusRingColor.followsAccent);
    CHECK_EQ_INT(config.warnings.count, 0);

    CASE("the outline is on by default and both shortcuts start empty");
    config = ARConfigFromValues(@{}, nil);
    CHECK(config.focusRing);
    CHECK(config.focusRingColor.followsAccent);
    CHECK(config.toggleShortcut == nil);
    CHECK(config.raiseShortcut == nil);

    CASE("the outline style has usable defaults");
    ARRingStyle style = ARRingStyleDefaults();
    CHECK_EQ_INT(style.placement, ARRingPlacementAround);
    CHECK(style.spread > 0 && style.spread <= 1);
    CHECK(style.falloff >= 0 && style.falloff <= 1);
    CHECK(style.width > 0);
    CHECK(style.pulseSeconds > 0);
    config = ARConfigFromValues(@{}, nil);
    CHECK_EQ_INT(config.focusRingStyle.glow, style.glow);

    CASE("every placement is spellable, old names included");
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingStyle": @"inline"}, nil).focusRingStyle.placement,
                 ARRingPlacementInside);
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingStyle": @"inside"}, nil).focusRingStyle.placement,
                 ARRingPlacementInside);
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingStyle": @"OUTSIDE"}, nil).focusRingStyle.placement,
                 ARRingPlacementAround);
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingStyle": @"top"}, nil).focusRingStyle.placement,
                 ARRingPlacementTop);
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingStyle": @" Right "}, nil).focusRingStyle.placement,
                 ARRingPlacementRight);
    ARConfig *bogusStyle = ARConfigFromValues(@{@"focusRingStyle": @"sideways"}, nil);
    CHECK_EQ_INT(bogusStyle.focusRingStyle.placement, ARRingPlacementAround);
    CHECK_EQ_INT(bogusStyle.warnings.count, 1);

    CASE("only the edge placements are bars");
    CHECK(!ARRingPlacementIsBar(ARRingPlacementAround));
    CHECK(!ARRingPlacementIsBar(ARRingPlacementInside));
    CHECK(ARRingPlacementIsBar(ARRingPlacementTop));
    CHECK(ARRingPlacementIsBar(ARRingPlacementBottom));
    CHECK(ARRingPlacementIsBar(ARRingPlacementLeft));
    CHECK(ARRingPlacementIsBar(ARRingPlacementRight));

    CASE("a placement survives a round trip through the settings file");
    for (NSString *name in @[@"outline", @"inline", @"top", @"bottom", @"left", @"right"]) {
        ARRingPlacement parsed = ARRingPlacementAround;
        CHECK(ARRingPlacementParse(name, &parsed));
        CHECK_EQ_STR(ARRingPlacementDescribe(parsed), name);
    }

    CASE("the bar dimensions are clamped like the rest");
    ARConfig *bar = ARConfigFromValues(@{@"focusRingStyle": @"top",
                                         @"focusRingSpread": @"5",
                                         @"focusRingFalloff": @"-1"}, nil);
    CHECK_EQ_INT(bar.focusRingStyle.spread * 100, 100);
    CHECK_EQ_INT(bar.focusRingStyle.falloff, 0);
    CHECK_EQ_INT(bar.warnings.count, 2);

    CASE("silly dimensions are clamped and reported, not refused");
    ARConfig *clamped = ARConfigFromValues(@{@"focusRingWidth": @"400",
                                             @"focusRingGlow": @"-5",
                                             @"focusRingOpacity": @"9"}, nil);
    CHECK_EQ_INT(clamped.focusRingStyle.width, 10);
    CHECK_EQ_INT(clamped.focusRingStyle.glow, 0);
    CHECK_EQ_INT(clamped.focusRingStyle.opacity, 1);
    CHECK_EQ_INT(clamped.warnings.count, 3);

    CASE("zero pulse means steady, and a flicker is slowed to a pulse");
    CHECK_EQ_INT(ARConfigFromValues(@{@"focusRingPulse": @"0"}, nil).focusRingStyle.pulseSeconds, 0);
    CHECK(ARConfigFromValues(@{@"focusRingPulse": @"0.01"}, nil).focusRingStyle.pulseSeconds >= 0.2);

    CASE("the two shortcuts are kept apart");
    config = ARConfigFromValues(@{@"toggleShortcut": @"control-option-J",
                                  @"raiseShortcut": @"control-option-K"}, nil);
    CHECK_EQ_STR(config.toggleShortcut, @"control-option-J");
    CHECK_EQ_STR(config.raiseShortcut, @"control-option-K");
}

//------------------------------------------------ shortcuts -----------------------------------------------

static void testShortcuts(void) {
    CASE("a shortcut needs modifiers and a key");
    ARShortcut shortcut = ARShortcutParse(@"control-option-A");
    CHECK(shortcut.valid);
    CHECK_EQ_INT(shortcut.modifiers, kCGEventFlagMaskControl | kCGEventFlagMaskAlternate);
    CHECK(ARShortcutParse(@"command-shift-F5").valid);
    CHECK(ARShortcutParse(@"cmd-ctrl-Space").valid);

    CASE("a bare key is refused, because it would fire while typing");
    CHECK(!ARShortcutParse(@"A").valid);
    CHECK(!ARShortcutParse(@"").valid);
    CHECK(!ARShortcutParse(nil).valid);

    CASE("nonsense is refused");
    CHECK(!ARShortcutParse(@"control-banana").valid);
    CHECK(!ARShortcutParse(@"control").valid);

    CASE("the stored spelling is normalised");
    CHECK_EQ_STR(ARShortcutDescribe(ARShortcutParse(@"option-control-A")), @"control-option-A");
    CHECK_EQ_STR(ARShortcutDescribe(ARShortcutParse(@"cmd-shift-A")), @"shift-command-A");
    CHECK_EQ_STR(ARShortcutDescribe(ARShortcutParse(@"ctrl-Space")), @"control-Space");

    CASE("the displayed spelling is the one macOS uses");
    CHECK_EQ_STR(ARShortcutDisplay(ARShortcutParse(@"control-option-A")), @"⌃⌥A");
    CHECK_EQ_STR(ARShortcutDisplay(ARShortcutParse(@"command-shift-Return")), @"⇧⌘↩");
    CHECK_EQ_STR(ARShortcutDisplay(ARShortcutParse(@"nonsense")), @"None");

    CASE("a shortcut survives a round trip through the settings file");
    ARConfig *config = ARConfigFromValues(@{@"toggleShortcut": @"option-control-J"}, nil);
    CHECK_EQ_STR(config.toggleShortcut, @"control-option-J");
    CHECK_EQ_INT(config.warnings.count, 0);

    CASE("an unusable shortcut is reported rather than kept");
    config = ARConfigFromValues(@{@"toggleShortcut": @"J"}, nil);
    CHECK(config.toggleShortcut == nil);
    CHECK_EQ_INT(config.warnings.count, 1);
}

//----------------------------------------------- writing --------------------------------------------------

static NSString *writeTemp(NSString *contents) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        @"autoraise-test-config"];
    [contents writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: nil];
    return path;
}

static NSString *readTemp(NSString *path) {
    return [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil];
}

static void testConfigWriting(void) {
    CASE("an existing setting is replaced where it stands");
    NSString *path = writeTemp(@"# my notes\ndelay=1\nverbose=false\n# trailing note\n");
    CHECK(ARConfigWrite(path, @{@"delay": @"4"}, nil));
    CHECK_EQ_STR(readTemp(path), @"# my notes\ndelay=4\nverbose=false\n# trailing note\n");

    CASE("a new setting is appended and the comments stay");
    path = writeTemp(@"# keep me\ndelay=1\n");
    CHECK(ARConfigWrite(path, @{@"mouseDelta": @"2"}, nil));
    NSString *result = readTemp(path);
    CHECK([result containsString: @"# keep me"]);
    CHECK([result containsString: @"delay=1"]);
    CHECK([result containsString: @"mouseDelta=2"]);

    CASE("a commented out setting stays a comment");
    path = writeTemp(@"#warpX=0.5\n");
    CHECK(ARConfigWrite(path, @{@"warpX": @"0.25"}, nil));
    result = readTemp(path);
    CHECK([result containsString: @"#warpX=0.5"]);
    CHECK([result containsString: @"warpX=0.25"]);

    CASE("NSNull removes a setting");
    path = writeTemp(@"warpX=0.5\nwarpY=0.5\ndelay=1\n");
    CHECK(ARConfigWrite(path, @{@"warpX": [NSNull null], @"warpY": [NSNull null]}, nil));
    result = readTemp(path);
    CHECK(![result containsString: @"warpX"]);
    CHECK(![result containsString: @"warpY"]);
    CHECK([result containsString: @"delay=1"]);

    CASE("settings this build does not know about are left alone");
    path = writeTemp(@"delay=1\nsomethingNewer=7\n");
    CHECK(ARConfigWrite(path, @{@"delay": @"2"}, nil));
    CHECK([readTemp(path) containsString: @"somethingNewer=7"]);

    CASE("what was written reads back the same");
    path = writeTemp(@"");
    CHECK(ARConfigWrite(path, @{@"delay": @"6", @"ignoreApps": @"Xcode"}, nil));
    NSDictionary *values = ARConfigParseFile(readTemp(path), [NSMutableArray array]);
    CHECK_EQ_STR(values[@"delay"], @"6");
    CHECK_EQ_STR(values[@"ignoreApps"], @"Xcode");

    [[NSFileManager defaultManager] removeItemAtPath: path error: nil];
}

//------------------------------------------------ intent --------------------------------------------------

// Walks the pointer from one place to another at a given speed, one sample every
// 8ms as a real mouse would, and returns the last reading.
static ARIntent glide(ARIntentReader *reader, CGPoint from, CGPoint to,
                      CGFloat pointsPerSecond, NSTimeInterval *clock) {
    CGFloat distance = hypot(to.x - from.x, to.y - from.y);
    NSTimeInterval duration = distance / pointsPerSecond;
    NSInteger steps = MAX(2, (NSInteger) (duration / 0.008));
    ARIntent intent = reader.intent;
    for (NSInteger i = 1; i <= steps; i++) {
        CGFloat progress = (CGFloat) i / steps;
        CGPoint point = CGPointMake(from.x + (to.x - from.x) * progress,
                                    from.y + (to.y - from.y) * progress);
        *clock += duration / steps;
        intent = [reader addPoint: point atTime: *clock];
    }
    return intent;
}

// Arrival is announced on one sample only, so a caller has to latch it. The app
// does the same thing: the event tap records it, the evaluation consumes it.
static ARIntent rest(ARIntentReader *reader, CGPoint at, NSTimeInterval seconds,
                     NSTimeInterval *clock) {
    ARIntent intent = reader.intent;
    BOOL arrived = NO;
    for (NSInteger i = 0; i < 10; i++) {
        *clock += seconds / 10;
        intent = [reader addPoint: at atTime: *clock];
        arrived = arrived || intent.arrived;
    }
    intent.arrived = arrived;
    return intent;
}

static void testIntent(void) {
    NSTimeInterval clock = 1000;

    CASE("crossing a window at speed is not arriving at it");
    ARIntentReader *reader = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessNormal)];
    ARIntent intent = glide(reader, CGPointMake(0, 0), CGPointMake(1400, 0), 2600, &clock);
    CHECK(!intent.settled);
    CHECK(intent.speed > 1000);

    CASE("stopping is arriving, and it is announced once");
    intent = rest(reader, CGPointMake(1400, 0), 0.20, &clock);
    CHECK(intent.settled);
    ARIntent again = rest(reader, CGPointMake(1400, 0), 0.20, &clock);
    CHECK(again.settled);
    CHECK(!again.arrived);      // still there, not newly arrived

    CASE("setting off again is travelling, and stopping arrives afresh");
    intent = glide(reader, CGPointMake(1400, 0), CGPointMake(200, 500), 2600, &clock);
    CHECK(!intent.settled);
    intent = rest(reader, CGPointMake(200, 500), 0.20, &clock);
    CHECK(intent.settled);
    CHECK(intent.arrived);

    CASE("a shaky hand is not travelling");
    ARIntentReader *shaky = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessNormal)];
    clock += 1;
    [shaky addPoint: CGPointMake(500, 500) atTime: clock];
    for (NSInteger i = 0; i < 40; i++) {
        clock += 0.008;
        intent = [shaky addPoint: CGPointMake(500 + (i % 2), 500 + ((i / 2) % 2))
                          atTime: clock];
    }
    CHECK(intent.settled);

    CASE("a slow deliberate move counts as arriving where it goes");
    ARIntentReader *careful = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessNormal)];
    clock += 1;
    intent = glide(careful, CGPointMake(0, 0), CGPointMake(120, 0), 80, &clock);
    CHECK(intent.settled);

    CASE("eagerness is the only dial: instant tolerates speed, relaxed does not");
    ARIntentReader *instant = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessInstant)];
    ARIntentReader *relaxed = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessRelaxed)];
    clock += 1;
    NSTimeInterval instantClock = clock, relaxedClock = clock;
    ARIntent quickArrival = glide(instant, CGPointMake(0, 0), CGPointMake(600, 0), 700,
                                  &instantClock);
    ARIntent slowArrival = glide(relaxed, CGPointMake(0, 0), CGPointMake(600, 0), 700,
                                 &relaxedClock);
    CHECK(quickArrival.settled);     // 700 pt/s is a settle for instant
    CHECK(!slowArrival.settled);     // and still travelling for relaxed

    CASE("a pointer put somewhere by software did not travel there");
    ARIntentReader *warped = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessNormal)];
    clock += 1;
    glide(warped, CGPointMake(0, 0), CGPointMake(400, 0), 3000, &clock);
    CHECK(![warped intent].settled);
    // One sample, a thousand points away, a millisecond later: a warp.
    clock += 0.001;
    ARIntent afterWarp = [warped addPoint: CGPointMake(1400, 600) atTime: clock];
    CHECK_EQ_INT(afterWarp.speed, 0);
    clock += 0.10;
    CHECK([warped addPoint: CGPointMake(1400, 600) atTime: clock].settled);

    CASE("a pointer nobody has reported on has arrived by definition");
    ARIntentReader *fresh = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessNormal)];
    CHECK([fresh settleAtTime: 5].settled);

    CASE("parking without any events still counts as arriving");
    ARIntentReader *parked = [[ARIntentReader alloc]
        initWithTuning: ARTuningFor(AREagernessRelaxed)];
    clock += 1;
    glide(parked, CGPointMake(0, 0), CGPointMake(800, 0), 3000, &clock);
    CHECK(![parked intent].settled);
    CHECK([parked settleAtTime: clock + 0.5].settled);

    CASE("every eagerness has a name that survives a round trip");
    for (NSString *name in @[@"instant", @"quick", @"normal", @"relaxed"]) {
        AREagerness eagerness = AREagernessNormal;
        CHECK(AREagernessParse(name, &eagerness));
        CHECK_EQ_STR(AREagernessDescribe(eagerness), name);
    }
    CHECK(!AREagernessParse(@"whenever", NULL));
    CHECK(AREagernessParse(@" PATIENT ", NULL));
}

//------------------------------------------------- stats ---------------------------------------------------

static void testStats(void) {
    CASE("a fresh tally counts nothing");
    ARStats *stats = [[ARStats alloc] initWithDictionary: nil];
    CHECK_EQ_INT(stats.clicksSaved, 0);
    CHECK_EQ_INT(stats.today, 0);
    CHECK_EQ_INT([stats topApps: 5].count, 0);

    CASE("raises and focuses both count as clicks saved, and are told apart");
    [stats recordAction: ARSavedActionRaised app: @"Safari" bundleId: @"com.apple.Safari"];
    [stats recordAction: ARSavedActionRaised app: @"Safari" bundleId: @"com.apple.Safari"];
    [stats recordAction: ARSavedActionFocused app: @"Terminal" bundleId: @"com.apple.Terminal"];
    CHECK_EQ_INT(stats.raises, 2);
    CHECK_EQ_INT(stats.focuses, 1);
    CHECK_EQ_INT(stats.clicksSaved, 3);
    CHECK_EQ_INT(stats.today, 3);

    CASE("nothing happening is not counted");
    [stats recordAction: ARSavedActionNone app: @"Safari" bundleId: @"com.apple.Safari"];
    CHECK_EQ_INT(stats.clicksSaved, 3);

    CASE("the shortcut counts too");
    [stats recordShortcutRaise];
    CHECK_EQ_INT(stats.shortcutRaises, 1);
    CHECK_EQ_INT(stats.clicksSaved, 4);

    CASE("warps are counted with the distance they covered");
    [stats recordWarpOver: 300];
    [stats recordWarpOver: 200];
    [stats recordWarpOver: 0];       // a warp that went nowhere is not one
    CHECK_EQ_INT(stats.warps, 2);
    CHECK_EQ_INT(stats.warpPixels, 500);

    CASE("the top applications come back in order, biggest first");
    NSArray<ARAppTally *> *top = [stats topApps: 5];
    CHECK_EQ_INT(top.count, 2);
    CHECK_EQ_STR(top.firstObject.name, @"Safari");
    CHECK_EQ_INT(top.firstObject.count, 2);
    CHECK_EQ_STR(top.lastObject.name, @"Terminal");

    CASE("the list is cut to the length asked for");
    CHECK_EQ_INT([stats topApps: 1].count, 1);

    CASE("the daily history ends today and is as long as asked");
    NSArray<NSNumber *> *days = [stats countsForLastDays: 14];
    CHECK_EQ_INT(days.count, 14);
    // Three hovers plus the shortcut raise; warps are travel, not clicks.
    CHECK_EQ_INT(days.lastObject.integerValue, 4);
    CHECK_EQ_INT(days.firstObject.integerValue, 0);

    CASE("everything survives a round trip through the file format");
    ARStats *restored = [[ARStats alloc] initWithDictionary: stats.dictionaryRepresentation];
    CHECK_EQ_INT(restored.clicksSaved, stats.clicksSaved);
    CHECK_EQ_INT(restored.raises, stats.raises);
    CHECK_EQ_INT(restored.warps, stats.warps);
    CHECK_EQ_INT(restored.warpPixels, stats.warpPixels);
    CHECK_EQ_INT([restored topApps: 5].count, 2);
    CHECK_EQ_STR([restored topApps: 5].firstObject.name, @"Safari");
    CHECK_EQ_INT(restored.today, stats.today);

    CASE("a damaged file leaves a working tally rather than a crash");
    ARStats *damaged = [[ARStats alloc] initWithDictionary:
        @{@"raises": @"lots", @"byDay": @[@1, @2], @"byApp": @{@"x": @"not a dictionary"}}];
    CHECK_EQ_INT(damaged.clicksSaved, 0);
    CHECK_EQ_INT([damaged topApps: 5].count, 0);

    CASE("an app with no bundle identifier is still counted");
    ARStats *nameless = [[ARStats alloc] initWithDictionary: nil];
    [nameless recordAction: ARSavedActionRaised app: @"XQuartz" bundleId: nil];
    CHECK_EQ_INT([nameless topApps: 5].count, 1);
    CHECK_EQ_STR([nameless topApps: 5].firstObject.name, @"XQuartz");
}

int main(void) {
    @autoreleasepool {
        testMatching();
        testMainWindow();
        testDecisions();
        testCorrections();
        testDelay();
        testConfigParsing();
        testConfigValues();
        testQuirks();
        testShortcuts();
        testColors();
        testConfigWriting();
        testStats();
        testIntent();

        printf("%d checks, %d failures\n", checks, failures);
        return failures ? 1 : 0;
    }
}
