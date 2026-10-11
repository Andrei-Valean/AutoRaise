/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Config.h"

#define AR_MIN_POLL_MILLIS 20

static NSString *const kMode = @"mode";
static NSString *const kEagerness = @"eagerness";
static NSString *const kRaiseAfter = @"raiseAfter";
// Kept only so that a settings file written for an older version still works.
static NSString *const kPollMillis = @"pollMillis";
static NSString *const kHeartbeatMillis = @"heartbeatMillis";
static NSString *const kDelay = @"delay";
static NSString *const kFocusDelay = @"focusDelay";
static NSString *const kMouseDelta = @"mouseDelta";
static NSString *const kRequireMouseStop = @"requireMouseStop";
static NSString *const kWarpX = @"warpX";
static NSString *const kWarpY = @"warpY";
static NSString *const kScale = @"scale";
static NSString *const kAltTaskSwitcher = @"altTaskSwitcher";
static NSString *const kIgnoreSpaceChanged = @"ignoreSpaceChanged";
static NSString *const kDialogPointer = @"dialogPointer";
static NSString *const kDialogPointerReturn = @"dialogPointerReturn";
static NSString *const kTypingGrace = @"typingGrace";
static NSString *const kReturnShortcut = @"returnShortcut";
static NSString *const kInvertDisableKey = @"invertDisableKey";
static NSString *const kInvertIgnoreApps = @"invertIgnoreApps";
static NSString *const kIgnoreApps = @"ignoreApps";
static NSString *const kIgnoreTitles = @"ignoreTitles";
static NSString *const kStayFocusedBundleIds = @"stayFocusedBundleIds";
static NSString *const kDisableKey = @"disableKey";
static NSString *const kLegacyActivation = @"legacyActivation";
static NSString *const kWindowServerHitTest = @"windowServerHitTest";
static NSString *const kMenuBarIcon = @"menuBarIcon";
static NSString *const kLiveReload = @"liveReload";
static NSString *const kVerbose = @"verbose";
static NSString *const kSelfRaisingApps = @"selfRaisingApps";
static NSString *const kFocusRing = @"focusRing";
static NSString *const kFocusRingColor = @"focusRingColor";
static NSString *const kFocusRingStyle = @"focusRingStyle";
static NSString *const kFocusRingWidth = @"focusRingWidth";
static NSString *const kFocusRingGlow = @"focusRingGlow";
static NSString *const kFocusRingRadius = @"focusRingRadius";
static NSString *const kFocusRingOpacity = @"focusRingOpacity";
static NSString *const kFocusRingPulse = @"focusRingPulse";
static NSString *const kFocusRingSpread = @"focusRingSpread";
static NSString *const kFocusRingFalloff = @"focusRingFalloff";
static NSString *const kRaiseShortcut = @"raiseShortcut";
static NSString *const kEnabled = @"enabled";
static NSString *const kToggleShortcut = @"toggleShortcut";
static NSString *const kPinShortcut = @"pinShortcut";
static NSString *const kConfig = @"config";

// Settings that no longer do anything on their own: they are translated into the
// mode and the eagerness, once, with a note saying so.
static NSArray<NSString *> *ARRetiredKeys(void) {
    return @[kPollMillis, kHeartbeatMillis, kDelay, kFocusDelay, kMouseDelta,
             kRequireMouseStop];
}

// Settings this version does without. Each is read one last time, so nothing
// changes behaviour silently, and each says what replaced it.
static NSDictionary<NSString *, NSString *> *ARDeletedKeys(void) {
    return @{
        kAltTaskSwitcher: @"AutoRaise now notices a task switcher by itself: a hotkey, then an "
                           "application coming forward",
        kInvertIgnoreApps: @"it became a rule for * in apps.json, which says what to do with "
                            "every application you have not named",
        kInvertDisableKey: @"still read for now, but write it as disableKey=!control instead",
    };
}

static NSArray<NSString *> *ARConfigKeys(void) {
    return @[kMode, kEagerness, kRaiseAfter,
             kPollMillis, kHeartbeatMillis, kDelay, kFocusDelay, kWarpX, kWarpY, kScale,
             kAltTaskSwitcher, kRequireMouseStop, kIgnoreSpaceChanged, kInvertDisableKey,
             kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles, kStayFocusedBundleIds,
             kDisableKey, kMouseDelta, kLegacyActivation, kWindowServerHitTest,
             kTypingGrace, kReturnShortcut, kDialogPointer, kDialogPointerReturn,
             kMenuBarIcon, kLiveReload, kVerbose, kEnabled, kToggleShortcut,
             kSelfRaisingApps, kFocusRing, kFocusRingColor, kFocusRingStyle, kFocusRingWidth,
             kFocusRingGlow, kFocusRingRadius, kFocusRingOpacity, kFocusRingPulse,
             kFocusRingSpread, kFocusRingFalloff,
             kRaiseShortcut, kPinShortcut, kConfig];
}

@implementation ARConfig

// Warping needs both factors, which is how it has always been switched on.
- (BOOL)warpMouse {
    return self.warpX >= 0 && self.warpX <= 1 && self.warpY >= 0 && self.warpY <= 1;
}

- (BOOL)focusFirst { return self.mode != ARHoverModeRaise; }
- (BOOL)raises { return self.mode != ARHoverModeFocus; }
- (ARIntentTuning)tuning { return ARTuningFor(self.eagerness); }

@end

BOOL ARHoverModeParse(NSString *text, ARHoverMode *mode) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"raise": @(ARHoverModeRaise),
                  @"focusthenraise": @(ARHoverModeFocusThenRaise),
                  @"focus-then-raise": @(ARHoverModeFocusThenRaise),
                  @"both": @(ARHoverModeFocusThenRaise),
                  @"focus": @(ARHoverModeFocus), @"focusonly": @(ARHoverModeFocus)};
    }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString] ?: @""];
    if (!found) { return NO; }
    if (mode) { *mode = (ARHoverMode) found.integerValue; }
    return YES;
}

NSString *ARHoverModeDescribe(ARHoverMode mode) {
    switch (mode) {
        case ARHoverModeFocusThenRaise: return @"focusThenRaise";
        case ARHoverModeFocus: return @"focus";
        default: return @"raise";
    }
}

BOOL ARSelfRaisingParse(NSString *text, ARSelfRaisingApps *mode) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"focus": @(ARSelfRaisingFocus), @"raise": @(ARSelfRaisingFocus),
                  @"quiet": @(ARSelfRaisingQuiet), @"quietly": @(ARSelfRaisingQuiet),
                  @"skip": @(ARSelfRaisingSkip), @"ignore": @(ARSelfRaisingSkip)};
    }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString] ?: @""];
    if (!found) { return NO; }
    if (mode) { *mode = (ARSelfRaisingApps) found.integerValue; }
    return YES;
}

NSString *ARSelfRaisingDescribe(ARSelfRaisingApps mode) {
    switch (mode) {
        case ARSelfRaisingQuiet: return @"quiet";
        case ARSelfRaisingSkip: return @"skip";
        default: return @"focus";
    }
}

ARRingStyle ARRingStyleDefaults(void) {
    ARRingStyle style = {ARRingPlacementAround, 2.0, 7.0, 11.0, 1.0, 1.1, 0.6, 0.7};
    return style;
}

BOOL ARRingPlacementIsBar(ARRingPlacement placement) {
    return placement >= ARRingPlacementTop;
}

// Both the historical spellings and the four edges.
BOOL ARRingPlacementParse(NSString *text, ARRingPlacement *placement) {
    static NSDictionary<NSString *, NSNumber *> *names = nil;
    if (!names) {
        names = @{@"outline": @(ARRingPlacementAround), @"outside": @(ARRingPlacementAround),
                  @"around": @(ARRingPlacementAround),
                  @"inline": @(ARRingPlacementInside), @"inside": @(ARRingPlacementInside),
                  @"top": @(ARRingPlacementTop), @"bottom": @(ARRingPlacementBottom),
                  @"left": @(ARRingPlacementLeft), @"right": @(ARRingPlacementRight)};
    }
    NSNumber *found = names[[[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString] ?: @""];
    if (!found) { return NO; }
    if (placement) { *placement = (ARRingPlacement) found.integerValue; }
    return YES;
}

NSString *ARRingPlacementDescribe(ARRingPlacement placement) {
    switch (placement) {
        case ARRingPlacementInside: return @"inline";
        case ARRingPlacementTop: return @"top";
        case ARRingPlacementBottom: return @"bottom";
        case ARRingPlacementLeft: return @"left";
        case ARRingPlacementRight: return @"right";
        default: return @"outline";
    }
}

// Accepts "accent", "#RGB", "#RRGGBB" and "#RRGGBBAA", with or without the hash.
ARColor ARColorParse(NSString *text, BOOL *ok) {
    ARColor color = {YES, 0, 0, 0, 1};
    if (ok) { *ok = YES; }
    NSString *value = [[text stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    if (!value.length || [value isEqualToString: @"accent"]) { return color; }

    if ([value hasPrefix: @"#"]) { value = [value substringFromIndex: 1]; }
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString: @"0123456789abcdef"];
    if ([value stringByTrimmingCharactersInSet: hex].length) {
        if (ok) { *ok = NO; }
        return color;
    }

    unsigned components[4] = {0, 0, 0, 255};
    if (value.length == 3) {
        for (int i = 0; i < 3; i++) {
            NSString *digit = [value substringWithRange: NSMakeRange(i, 1)];
            unsigned n = (unsigned) strtoul(digit.UTF8String, NULL, 16);
            components[i] = n * 17;   // #abc means #aabbcc
        }
    } else if (value.length == 6 || value.length == 8) {
        for (NSUInteger i = 0; i < value.length / 2; i++) {
            NSString *pair = [value substringWithRange: NSMakeRange(i * 2, 2)];
            components[i] = (unsigned) strtoul(pair.UTF8String, NULL, 16);
        }
    } else {
        if (ok) { *ok = NO; }
        return color;
    }

    color.followsAccent = NO;
    color.red = components[0] / 255.0;
    color.green = components[1] / 255.0;
    color.blue = components[2] / 255.0;
    color.alpha = components[3] / 255.0;
    return color;
}

NSString *ARColorDescribe(ARColor color) {
    if (color.followsAccent) { return @"accent"; }
    if (color.alpha >= 1.0) {
        return [NSString stringWithFormat: @"#%02X%02X%02X",
            (unsigned) round(color.red * 255), (unsigned) round(color.green * 255),
            (unsigned) round(color.blue * 255)];
    }
    return [NSString stringWithFormat: @"#%02X%02X%02X%02X",
        (unsigned) round(color.red * 255), (unsigned) round(color.green * 255),
        (unsigned) round(color.blue * 255), (unsigned) round(color.alpha * 255)];
}

// Splits on commas, honouring a backslash escape so that an app name or a
// regular expression may contain one.
NSArray<NSString *> *ARSplitList(NSString *value, BOOL trimEntries) {
    if (!value.length) { return @[]; }
    NSMutableArray *entries = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    BOOL escaped = NO;
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar c = [value characterAtIndex: i];
        if (escaped) {
            // Only "\," is consumed as an escape; every other backslash is kept
            // so regular expressions such as "\\s\\|" survive untouched.
            if (c != ',') { [current appendString: @"\\"]; }
            [current appendFormat: @"%C", c];
            escaped = NO;
        } else if (c == '\\') {
            escaped = YES;
        } else if (c == ',') {
            [entries addObject: [current copy]];
            current = [NSMutableString string];
        } else {
            [current appendFormat: @"%C", c];
        }
    }
    if (escaped) { [current appendString: @"\\"]; }
    [entries addObject: [current copy]];

    NSMutableArray *result = [NSMutableArray array];
    for (NSString *entry in entries) {
        NSString *cleaned = trimEntries
            ? [entry stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]]
            : entry;
        if (cleaned.length) { [result addObject: cleaned]; }
    }
    return [result copy];
}

static NSString *ARStripQuotes(NSString *value) {
    if (value.length >= 2) {
        unichar first = [value characterAtIndex: 0];
        unichar last = [value characterAtIndex: value.length - 1];
        if ((first == '"' && last == '"') || (first == '\'' && last == '\'')) {
            return [value substringWithRange: NSMakeRange(1, value.length - 2)];
        }
    }
    return value;
}

NSDictionary<NSString *, NSString *> *ARConfigParseFile(NSString *contents,
                                                       NSMutableArray<NSString *> *warnings) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray<NSString *> *known = ARConfigKeys();
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    int lineNumber = 0;

    for (NSString *rawLine in [contents componentsSeparatedByString: @"\n"]) {
        lineNumber++;
        NSString *line = [rawLine stringByTrimmingCharactersInSet: space];
        if (!line.length || [line hasPrefix: @"#"]) { continue; }

        // Split on the first "=" only: a title pattern may contain more.
        NSRange separator = [line rangeOfString: @"="];
        if (separator.location == NSNotFound) {
            [warnings addObject: [NSString stringWithFormat: @"line %d: expected key=value, got \"%@\"",
                                  lineNumber, line]];
            continue;
        }

        NSString *key = [[line substringToIndex: separator.location] stringByTrimmingCharactersInSet: space];
        NSString *value = [[line substringFromIndex: NSMaxRange(separator)] stringByTrimmingCharactersInSet: space];
        if (![known containsObject: key]) {
            [warnings addObject: [NSString stringWithFormat: @"line %d: unknown setting \"%@\"", lineNumber, key]];
            continue;
        }
        values[key] = ARStripQuotes(value);
    }
    return values;
}

NSDictionary<NSString *, NSString *> *ARConfigParseArguments(int argc, const char *argv[],
                                                            NSMutableArray<NSString *> *warnings) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray<NSString *> *known = ARConfigKeys();

    for (int i = 1; i < argc; i++) {
        NSString *argument = [NSString stringWithUTF8String: argv[i]];
        if (![argument hasPrefix: @"-"]) {
            [warnings addObject: [NSString stringWithFormat: @"ignoring stray argument \"%@\"", argument]];
            continue;
        }
        NSString *key = [argument substringFromIndex: 1];
        if ([key hasPrefix: @"-"]) { key = [key substringFromIndex: 1]; }

        // -key=value works as well as -key value.
        NSRange inline_separator = [key rangeOfString: @"="];
        NSString *value = nil;
        if (inline_separator.location != NSNotFound) {
            value = ARStripQuotes([key substringFromIndex: NSMaxRange(inline_separator)]);
            key = [key substringToIndex: inline_separator.location];
        }

        if (![known containsObject: key]) {
            [warnings addObject: [NSString stringWithFormat: @"unknown option \"-%@\"", key]];
            if (!value && i + 1 < argc && argv[i + 1][0] != '-') { i++; }
            continue;
        }
        if (!value) {
            if (i + 1 >= argc) {
                [warnings addObject: [NSString stringWithFormat: @"-%@ needs a value", key]];
                continue;
            }
            value = ARStripQuotes([NSString stringWithUTF8String: argv[++i]]);
        }
        values[key] = value;
    }
    return values;
}

static BOOL ARBool(NSDictionary *values, NSString *key, BOOL fallback) {
    NSString *value = values[key];
    if (!value) { return fallback; }
    return [value boolValue] || [value isEqualToString: @"1"] ||
           [value caseInsensitiveCompare: @"yes"] == NSOrderedSame;
}

// Every dimension is clamped rather than refused, so a silly number in the file
// still leaves a ring you can see.
static CGFloat ARClamped(NSDictionary *values, NSString *key, CGFloat fallback,
                         CGFloat low, CGFloat high, NSMutableArray *warnings) {
    NSString *text = values[key];
    if (!text.length) { return fallback; }
    CGFloat value = [text doubleValue];
    CGFloat clamped = fmin(fmax(value, low), high);
    if (fabs(clamped - value) > 0.0001) {
        [warnings addObject: [NSString stringWithFormat: @"%@ %@ is outside %g to %g, using %g",
            key, text, low, high, clamped]];
    }
    return clamped;
}

static ARRingStyle ARRingStyleFromValues(NSDictionary *values, NSMutableArray *warnings) {
    ARRingStyle style = ARRingStyleDefaults();

    NSString *placement = values[kFocusRingStyle];
    if (placement.length && !ARRingPlacementParse(placement, &style.placement)) {
        [warnings addObject: [NSString stringWithFormat:
            @"focusRingStyle \"%@\" is not outline, inline, top, bottom, left or right",
            placement]];
    }

    style.width = ARClamped(values, kFocusRingWidth, style.width, 0.5, 10, warnings);
    style.glow = ARClamped(values, kFocusRingGlow, style.glow, 0, 24, warnings);
    style.radius = ARClamped(values, kFocusRingRadius, style.radius, 0, 32, warnings);
    style.opacity = ARClamped(values, kFocusRingOpacity, style.opacity, 0.1, 1, warnings);
    // Anything under a fifth of a second reads as a flicker rather than a pulse.
    CGFloat pulse = ARClamped(values, kFocusRingPulse, style.pulseSeconds, 0, 6, warnings);
    style.pulseSeconds = pulse > 0 && pulse < 0.2 ? 0.2 : pulse;
    style.spread = ARClamped(values, kFocusRingSpread, style.spread, 0.05, 1, warnings);
    style.falloff = ARClamped(values, kFocusRingFalloff, style.falloff, 0, 1, warnings);
    return style;
}

// A settings file written for an older version describes the same intentions in
// units that no longer exist: a delay counted in polling intervals, a dead zone,
// and a stop requirement. They are read once, turned into a mode and an
// eagerness, and said out loud so nobody wonders where they went.
@interface ARConfig (Retired)
- (void)adoptRetiredSettings:(NSDictionary *)values warnings:(NSMutableArray *)warnings;
@end

@implementation ARConfig (Retired)

- (void)adoptRetiredSettings:(NSDictionary *)values warnings:(NSMutableArray *)warnings {
    NSMutableArray *retired = [NSMutableArray array];
    for (NSString *key in ARRetiredKeys()) {
        if (values[key]) { [retired addObject: key]; }
    }
    if (!retired.count) { return; }

    int poll = values[kPollMillis] ? MAX(1, [values[kPollMillis] intValue]) : 50;
    BOOL hasDelay = values[kDelay] != nil, hasFocusDelay = values[kFocusDelay] != nil;
    int delay = [values[kDelay] intValue], focusDelay = [values[kFocusDelay] intValue];

    // The old pair of counters said which of the three things should happen.
    if (!values[kMode]) {
        if ((hasFocusDelay && focusDelay > 0) || (hasDelay && delay == 0)) {
            self.mode = (hasDelay && delay > 0) ? ARHoverModeFocusThenRaise : ARHoverModeFocus;
            if (self.mode == ARHoverModeFocusThenRaise) {
                self.raiseAfterMillis = MAX(0, (delay - 1) * poll);
            }
        } else {
            self.mode = ARHoverModeRaise;
        }
    }

    // And the counter that was in force said how long to wait.
    if (!values[kEagerness]) {
        int ticks = (hasFocusDelay && focusDelay > 0) ? focusDelay : delay;
        int waited = MAX(0, (ticks - 1) * poll);
        if (!ARBool(values, kRequireMouseStop, YES) || waited == 0) {
            self.eagerness = AREagernessInstant;
        } else if (waited <= 60) {
            self.eagerness = AREagernessQuick;
        } else if (waited <= 200) {
            self.eagerness = AREagernessNormal;
        } else {
            self.eagerness = AREagernessRelaxed;
        }
    }

    [warnings addObject: [NSString stringWithFormat:
        @"%@ no longer exist: hovering now reads the pointer's movement instead of counting "
         "polling intervals. Read as mode=%@, eagerness=%@; remove them from the file to "
         "silence this.",
        [retired componentsJoinedByString: @", "], ARHoverModeDescribe(self.mode),
        AREagernessDescribe(self.eagerness)]];
}

@end

ARConfig *ARConfigFromValues(NSDictionary<NSString *, NSString *> *values,
                             NSArray<NSString *> *warnings) {
    ARConfig *config = [[ARConfig alloc] init];
    NSMutableArray *allWarnings = [(warnings ?: @[]) mutableCopy];

    ARHoverMode mode = ARHoverModeRaise;
    if (values[kMode].length && !ARHoverModeParse(values[kMode], &mode)) {
        [allWarnings addObject: [NSString stringWithFormat:
            @"mode \"%@\" is not raise, focusThenRaise or focus", values[kMode]]];
    }
    config.mode = mode;

    AREagerness eagerness = AREagernessNormal;
    if (values[kEagerness].length && !AREagernessParse(values[kEagerness], &eagerness)) {
        [allWarnings addObject: [NSString stringWithFormat:
            @"eagerness \"%@\" is not instant, quick, normal or relaxed", values[kEagerness]]];
    }
    config.eagerness = eagerness;
    config.raiseAfterMillis = values[kRaiseAfter] ? [values[kRaiseAfter] intValue] : 400;
    if (config.raiseAfterMillis < 0) { config.raiseAfterMillis = 0; }

    [config adoptRetiredSettings: values warnings: allWarnings];
    for (NSString *key in ARDeletedKeys()) {
        if (!values[key]) { continue; }
        [allWarnings addObject: [NSString stringWithFormat: @"%@ no longer exists: %@",
                                 key, ARDeletedKeys()[key]]];
    }

    config.warpX = values[kWarpX] ? [values[kWarpX] floatValue] : -1;
    config.warpY = values[kWarpY] ? [values[kWarpY] floatValue] : -1;
    config.cursorScale = values[kScale] ? [values[kScale] floatValue] : 2.0;
    if (config.cursorScale < 1) { config.cursorScale = 2.0; }

    config.ignoreSpaceChanged = ARBool(values, kIgnoreSpaceChanged, NO);

    ARDialogAim aim = ARDialogAimOff;
    if (values[kDialogPointer] && !ARDialogAimParse(values[kDialogPointer], &aim)) {
        [allWarnings addObject: [NSString stringWithFormat:
            @"dialogPointer \"%@\" is not off, default, cancel or nearest",
            values[kDialogPointer]]];
    }
    config.dialogAim = aim;
    config.dialogPointerReturn = ARBool(values, kDialogPointerReturn, YES);
    config.typingGraceMillis = values[kTypingGrace] ? [values[kTypingGrace] intValue] : 700;
    if (config.typingGraceMillis < 0) { config.typingGraceMillis = 0; }
    // Read once so the table can adopt it, then never consulted again.
    config.invertIgnoreApps = ARBool(values, kInvertIgnoreApps, NO);
    config.legacyActivation = ARBool(values, kLegacyActivation, NO);
    config.windowServerHitTest = ARBool(values, kWindowServerHitTest, YES);
    config.menuBarIcon = ARBool(values, kMenuBarIcon, YES);
    config.liveReload = ARBool(values, kLiveReload, YES);
    config.verbose = ARBool(values, kVerbose, NO);
    config.enabled = ARBool(values, kEnabled, YES);

    for (NSString *key in @[kToggleShortcut, kRaiseShortcut, kReturnShortcut, kPinShortcut]) {
        NSString *shortcut = values[key];
        if (!shortcut.length || [shortcut isEqualToString: @"none"]) { continue; }
        ARShortcut parsed = ARShortcutParse(shortcut);
        if (!parsed.valid) {
            [allWarnings addObject: [NSString stringWithFormat:
                @"%@ \"%@\" is not a shortcut, for example control-option-A", key, shortcut]];
            continue;
        }
        if ([key isEqualToString: kToggleShortcut]) {
            config.toggleShortcut = ARShortcutDescribe(parsed);
        } else if ([key isEqualToString: kRaiseShortcut]) {
            config.raiseShortcut = ARShortcutDescribe(parsed);
        } else if ([key isEqualToString: kPinShortcut]) {
            config.pinShortcut = ARShortcutDescribe(parsed);
        } else {
            config.returnShortcut = ARShortcutDescribe(parsed);
        }
    }

    ARSelfRaisingApps selfRaising = ARSelfRaisingFocus;
    if (values[kSelfRaisingApps].length &&
        !ARSelfRaisingParse(values[kSelfRaisingApps], &selfRaising)) {
        [allWarnings addObject: [NSString stringWithFormat:
            @"selfRaisingApps \"%@\" is not focus, quiet or skip", values[kSelfRaisingApps]]];
    }
    config.selfRaisingApps = selfRaising;

    config.focusRing = ARBool(values, kFocusRing, YES);
    config.focusRingStyle = ARRingStyleFromValues(values, allWarnings);
    BOOL colorOk = YES;
    config.focusRingColor = ARColorParse(values[kFocusRingColor], &colorOk);
    if (!colorOk) {
        [allWarnings addObject: [NSString stringWithFormat:
            @"focusRingColor \"%@\" is not a colour, for example #0A84FF or accent",
            values[kFocusRingColor]]];
    }


    NSString *disableKey = values[kDisableKey] ?: @"control";
    // "!control" means the opposite: hold the key to allow raising rather than
    // to suspend it. One setting says both things.
    config.invertDisableKey = [disableKey hasPrefix: @"!"] ||
                              ARBool(values, kInvertDisableKey, NO);
    if ([disableKey hasPrefix: @"!"]) { disableKey = [disableKey substringFromIndex: 1]; }
    if ([disableKey isEqualToString: @"control"]) {
        config.disableKey = kCGEventFlagMaskControl;
    } else if ([disableKey isEqualToString: @"option"]) {
        config.disableKey = kCGEventFlagMaskAlternate;
    } else if ([disableKey isEqualToString: @"command"]) {
        config.disableKey = kCGEventFlagMaskCommand;
    } else if ([disableKey isEqualToString: @"shift"]) {
        config.disableKey = kCGEventFlagMaskShift;
    } else {
        if (![disableKey isEqualToString: @"disabled"]) {
            [allWarnings addObject: [NSString stringWithFormat:
                @"disableKey \"%@\" is not control, option, command, shift or disabled, "
             "each of which may be written with a ! in front", disableKey]];
        }
        config.disableKey = 0;
        disableKey = @"disabled";
    }
    config.disableKeyName = disableKey;

    config.ignoreApps = ARSplitList(values[kIgnoreApps], YES);
    config.ignoreTitles = ARSplitList(values[kIgnoreTitles], NO);
    config.stayFocusedBundleIds = ARSplitList(values[kStayFocusedBundleIds], YES);
    config.warnings = [allWarnings copy];
    return config;
}

NSString *ARConfigExistingPath(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *candidate in @[@".AutoRaise", @".config/AutoRaise/config"]) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent: candidate];
        if ([files fileExistsAtPath: path]) { return path; }
    }
    return nil;
}

NSString *ARConfigPreferredPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent: @".config/AutoRaise/config"];
}

static ARConfig *ARConfigBuild(NSString *_Nullable path, NSDictionary *arguments,
                               NSMutableArray *warnings) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSString *source = nil;

    if (path) {
        NSError *error = nil;
        NSString *contents = [NSString stringWithContentsOfFile: path
            encoding: NSUTF8StringEncoding error: &error];
        if (contents) {
            [values addEntriesFromDictionary: ARConfigParseFile(contents, warnings)];
            source = path;
        } else {
            [warnings addObject: [NSString stringWithFormat: @"cannot read %@: %@",
                                  path, error.localizedDescription]];
        }
    }

    // Command line arguments override the file rather than replacing it.
    [values addEntriesFromDictionary: arguments];

    ARConfig *config = ARConfigFromValues(values, warnings);
    config.sourcePath = source;
    return config;
}

// Live reload keeps the command line overrides that were given at startup.
static NSDictionary *ARStartupArguments = nil;

ARConfig *ARConfigLoad(int argc, const char *argv[]) {
    NSMutableArray *warnings = [NSMutableArray array];
    NSDictionary *arguments = ARConfigParseArguments(argc, argv, warnings);
    NSString *path = arguments[kConfig] ?: ARConfigExistingPath();
    if (arguments[kConfig] && ![[NSFileManager defaultManager] fileExistsAtPath: path]) {
        [warnings addObject: [NSString stringWithFormat: @"%@ does not exist", path]];
        path = nil;
    }
    ARStartupArguments = [arguments copy];
    ARConfig *config = ARConfigBuild(path, arguments, warnings);
    if (arguments[kConfig]) { config.sourcePath = path; }
    return config;
}

void ARConfigForgetArguments(NSArray<NSString *> *keys) {
    if (!ARStartupArguments.count) { return; }
    NSMutableDictionary *remaining = [ARStartupArguments mutableCopy];
    [remaining removeObjectsForKeys: keys];
    ARStartupArguments = [remaining copy];
}

ARConfig *ARConfigReload(ARConfig *previous) {
    NSMutableArray *warnings = [NSMutableArray array];
    NSString *path = previous.sourcePath ?: ARConfigExistingPath();
    ARConfig *config = ARConfigBuild(path, ARStartupArguments ?: @{}, warnings);
    return config;
}

NSString *ARConfigTemplate(void) {
    return @"# AutoRaise configuration. Reloaded automatically when saved.\n"
            "# Every setting is optional; the values below are the defaults.\n"
            "\n"
            "# What hovering a window does: raise, focusThenRaise, or focus.\n"
            "mode=raise\n"
            "# How readily, read from the pointer slowing down rather than a stopwatch:\n"
            "# instant, quick, normal or relaxed.\n"
            "eagerness=normal\n"
            "# In focusThenRaise, how long after focusing to bring the window forward.\n"
            "raiseAfter=400\n"
            "\n"
            "# Warp the mouse into the window activated by cmd-tab or cmd-grave.\n"
            "# Both factors are between 0 and 1; leave them out to disable warping.\n"
            "#warpX=0.5\n"
            "#warpY=0.1\n"
            "#scale=2.5\n"
            "\n"
            "\n"
            "# Browsers and some editors bring themselves to the front the moment they\n"
            "# are focused. focus lets them; quiet hands them the keyboard without the\n"
            "# events they react to, so they stay put, at the cost of the application\n"
            "# choosing which of its own windows takes the keyboard; skip leaves them\n"
            "# alone. The list is the appsRaisingOnFocus quirk.\n"
            "selfRaisingApps=focus\n"
            "ignoreSpaceChanged=false\n"
            "\n"
            "# When a dialog appears, put the pointer on one of its buttons: off,\n"
            "# default (the one Return would press), cancel, or nearest. The pointer is\n"
            "# never left on a destructive button, whichever you choose.\n"
            "dialogPointer=off\n"
            "dialogPointerReturn=true # and put it back where it was afterwards\n"
            "\n"
            "# Hold this key to suspend AutoRaise: control, option, command, shift, disabled.\n"
            "disableKey=control       # a ! in front holds to allow instead: !control\n"
            "\n"
            "# Per-application behaviour now lives in apps.json next to this file,\n"
            "# one line per application, which the Exceptions page writes for you.\n"
            "# These three are the older form of the same thing and still work.\n"
            "# App entries match a localized name or a bundle identifier; titles are\n"
            "# ICU regular expressions. Escape a literal comma as \\,\n"
            "#ignoreApps=\"IntelliJ IDEA,com.jetbrains.WebStorm\"\n"
            "#ignoreTitles=\"^window$\"\n"
            "#stayFocusedBundleIds=\"com.apple.SecurityAgent\"\n"
            "\n"
            "# Ask the window server which window is under the mouse instead of asking\n"
            "# the hovered application. Faster, and immune to unresponsive apps.\n"
            "windowServerHitTest=true\n"
            "# Activate windows the pre-10.15 way, for GTK, SDL and wine apps.\n"
            "legacyActivation=false\n"
            "\n"
            "menuBarIcon=true\n"
            "liveReload=true\n"
            "verbose=false\n"
            "\n"
            "# While focus-first has a window focused but not raised, outline it.\n"
            "# The colour is a hex value, or \"accent\" to follow the system.\n"
            "focusRing=true\n"
            "focusRingColor=accent\n"
            "# outline and inline trace the whole window; top, bottom, left and right\n"
            "# draw one bar along that edge, brightest in the middle.\n"
            "focusRingStyle=outline\n"
            "focusRingWidth=2\n"
            "focusRingGlow=7           # 0 for a plain line\n"
            "focusRingRadius=11\n"
            "focusRingOpacity=1.0\n"
            "focusRingPulse=1.1        # seconds per breath, 0 to hold steady\n"
            "focusRingSpread=0.6       # bars: how much of the edge they cover\n"
            "focusRingFalloff=0.7      # bars: 0 ends abruptly, 1 fades the whole way\n"
            "# While you are typing you are not asking to change windows. How long\n"
            "# after the last keystroke hovering leaves the keyboard alone.\n"
            "typingGrace=700\n"
            "\n"
            "# Shortcuts, for example control-option-J. Leave out for none.\n"
            "#toggleShortcut=none\n"
            "#raiseShortcut=none\n"
            "#returnShortcut=none     # back to the window you came from\n"
            "# Keep the window under the pointer above everything; again to let go.\n"
            "# Needs the Screen Recording permission.\n"
            "#pinShortcut=none\n";
}

NSString *ARConfigUsage(void) {
    return @"AutoRaise\n"
            "  -mode <raise|focusThenRaise|focus>    what hovering does\n"
            "  -eagerness <instant|quick|normal|relaxed>\n"
            "  -raiseAfter <400>                     ms, for focusThenRaise\n"
            "  -warpX <0.5> -warpY <0.5> -scale <2.0>\n"
            "  -selfRaisingApps <focus|quiet|skip>   apps that raise themselves on focus\n"
            "  -ignoreSpaceChanged <true|false>\n"
            "  -dialogPointer <off|default|cancel|nearest>  aim at a dialog's button\n"
            "  -dialogPointerReturn <true|false>     and put the pointer back afterwards\n"
            "  -ignoreApps \"<App1,com.example.app2, ...>\"\n"
            "  -ignoreTitles \"<Regex1,Regex2, ...>\"\n"
            "  -stayFocusedBundleIds \"<Id1,Id2, ...>\"\n"
            "  -disableKey <[!]control|option|command|shift|disabled>\n"
            "  -windowServerHitTest <true|false>     ask the window server, not the app\n"
            "  -legacyActivation <true|false>        for GTK, SDL and wine apps\n"
            "  -menuBarIcon <true|false>\n"
            "  -liveReload <true|false>\n"
            "  -focusRing <true|false>               outline a focused, unraised window\n"
            "  -focusRingColor <#0A84FF|accent>\n"
            "  -focusRingStyle <outline|inline|top|bottom|left|right>\n"
            "  -focusRingSpread <0.6> -focusRingFalloff <0.7>   for the bar styles\n"
            "  -focusRingWidth <2> -focusRingGlow <7> -focusRingRadius <11>\n"
            "  -focusRingOpacity <1.0> -focusRingPulse <1.1>\n"
            "  -toggleShortcut <control-option-J>    pause and resume from anywhere\n"
            "  -raiseShortcut <control-option-K>     raise the outlined window\n"
            "  -returnShortcut <control-option-B>    back to the previous window\n"
            "  -pinShortcut <control-option-P>       keep the window under the pointer on top\n"
            "  -typingGrace <700>                    ms after a keystroke to leave focus alone\n"
            "  -verbose <true|false>\n"
            "  -config <path>                        use this file instead of the default\n"
            "  -dumpQuirks                           print the built-in app quirks\n"
            "  -probe                                report which window is under the mouse\n"
            "  -help, -version\n";
}


NSString *ARConfigSummary(ARConfig *config) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat: @"Settings from %@:\n", config.sourcePath ?: @"defaults and arguments"];
    [out appendFormat: @"  * on hover: %@\n", ARHoverModeDescribe(config.mode)];
    if (config.mode == ARHoverModeFocusThenRaise) {
        [out appendFormat: @"  * raise after: %dms\n", config.raiseAfterMillis];
    }
    ARIntentTuning tuning = config.tuning;
    [out appendFormat: @"  * eagerness: %@ (settles under %.0f pt/s, holds %.0fms)\n",
        AREagernessDescribe(config.eagerness), tuning.settleSpeed, tuning.confirm * 1000];
    if (config.warpMouse) {
        [out appendFormat: @"  * warpX: %.2f, warpY: %.2f, scale: %.1f\n",
            config.warpX, config.warpY, config.cursorScale];
    }
    [out appendFormat: @"  * ignoreSpaceChanged: %s\n", config.ignoreSpaceChanged ? "true" : "false"];
    if (config.dialogAim != ARDialogAimOff) {
        [out appendFormat: @"  * dialogPointer: %@%@\n", ARDialogAimDescribe(config.dialogAim),
            config.dialogPointerReturn ? @", put back afterwards" : @""];
    }
    [out appendFormat: @"  * disableKey: %@%@\n", config.disableKeyName,
        config.invertDisableKey ? @" (inverted)" : @""];
    for (NSString *app in config.ignoreApps) {
        [out appendFormat: @"  * ignoreApp: %@\n", app];
    }
    for (NSString *title in config.ignoreTitles) { [out appendFormat: @"  * ignoreTitle: %@\n", title]; }
    for (NSString *bundleId in config.stayFocusedBundleIds) {
        [out appendFormat: @"  * stayFocusedBundleId: %@\n", bundleId];
    }
    [out appendFormat: @"  * hitTest: %@\n", config.windowServerHitTest ? @"window server" : @"accessibility"];
    if (config.legacyActivation) { [out appendString: @"  * legacyActivation: true\n"]; }
    [out appendFormat: @"  * menuBarIcon: %s, liveReload: %s, verbose: %s\n",
        config.menuBarIcon ? "true" : "false", config.liveReload ? "true" : "false",
        config.verbose ? "true" : "false"];
    for (NSString *warning in config.warnings) { [out appendFormat: @"  ! %@\n", warning]; }
    return out;
}

//---------------------------------------------- writing ---------------------------------------------------

NSString *ARConfigEnsurePath(NSError **error) {
    NSString *path = ARConfigExistingPath();
    if (path) { return path; }

    path = ARConfigPreferredPath();
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files createDirectoryAtPath: path.stringByDeletingLastPathComponent
            withIntermediateDirectories: YES attributes: nil error: error]) {
        return nil;
    }
    if (![ARConfigTemplate() writeToFile: path atomically: YES
            encoding: NSUTF8StringEncoding error: error]) {
        return nil;
    }
    return path;
}

// Rewrites only the lines it has to. Hand written comments, ordering and
// settings this build does not know about all survive.
BOOL ARConfigWrite(NSString *path, NSDictionary<NSString *, id> *changes, NSError **error) {
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    NSString *contents = [NSString stringWithContentsOfFile: path
        encoding: NSUTF8StringEncoding error: nil] ?: ARConfigTemplate();

    NSMutableArray<NSString *> *lines =
        [[contents componentsSeparatedByString: @"\n"] mutableCopy];
    NSMutableSet<NSString *> *handled = [NSMutableSet set];

    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet: space];
        if (!line.length || [line hasPrefix: @"#"]) { continue; }
        NSRange separator = [line rangeOfString: @"="];
        if (separator.location == NSNotFound) { continue; }

        NSString *key = [[line substringToIndex: separator.location] stringByTrimmingCharactersInSet: space];
        id value = changes[key];
        if (!value || [handled containsObject: key]) { continue; }

        [handled addObject: key];
        if ([value isKindOfClass: [NSNull class]]) {
            [lines removeObjectAtIndex: i--];
        } else {
            lines[i] = [NSString stringWithFormat: @"%@=%@", key, value];
        }
    }

    NSMutableArray<NSString *> *added = [NSMutableArray array];
    for (NSString *key in changes) {
        if ([handled containsObject: key]) { continue; }
        if ([changes[key] isKindOfClass: [NSNull class]]) { continue; }
        [added addObject: [NSString stringWithFormat: @"%@=%@", key, changes[key]]];
    }
    if (added.count) {
        // Sorted, so a file the settings window has grown stays readable.
        [added sortUsingSelector: @selector(compare:)];
        while (lines.count && ![lines.lastObject stringByTrimmingCharactersInSet: space].length) {
            [lines removeLastObject];
        }
        [lines addObject: @""];
        [lines addObjectsFromArray: added];
    }

    NSString *result = [lines componentsJoinedByString: @"\n"];
    if (![result hasSuffix: @"\n"]) { result = [result stringByAppendingString: @"\n"]; }
    return [result writeToFile: path atomically: YES encoding: NSUTF8StringEncoding error: error];
}
