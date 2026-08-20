/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Config.h"

#define AR_MIN_POLL_MILLIS 20

static NSString *const kPollMillis = @"pollMillis";
static NSString *const kHeartbeatMillis = @"heartbeatMillis";
static NSString *const kDelay = @"delay";
static NSString *const kFocusDelay = @"focusDelay";
static NSString *const kWarpX = @"warpX";
static NSString *const kWarpY = @"warpY";
static NSString *const kScale = @"scale";
static NSString *const kAltTaskSwitcher = @"altTaskSwitcher";
static NSString *const kRequireMouseStop = @"requireMouseStop";
static NSString *const kIgnoreSpaceChanged = @"ignoreSpaceChanged";
static NSString *const kInvertDisableKey = @"invertDisableKey";
static NSString *const kInvertIgnoreApps = @"invertIgnoreApps";
static NSString *const kIgnoreApps = @"ignoreApps";
static NSString *const kIgnoreTitles = @"ignoreTitles";
static NSString *const kStayFocusedBundleIds = @"stayFocusedBundleIds";
static NSString *const kDisableKey = @"disableKey";
static NSString *const kMouseDelta = @"mouseDelta";
static NSString *const kLegacyActivation = @"legacyActivation";
static NSString *const kWindowServerHitTest = @"windowServerHitTest";
static NSString *const kMenuBarIcon = @"menuBarIcon";
static NSString *const kLiveReload = @"liveReload";
static NSString *const kVerbose = @"verbose";
static NSString *const kConfig = @"config";

static NSArray<NSString *> *ARConfigKeys(void) {
    return @[kPollMillis, kHeartbeatMillis, kDelay, kFocusDelay, kWarpX, kWarpY, kScale,
             kAltTaskSwitcher, kRequireMouseStop, kIgnoreSpaceChanged, kInvertDisableKey,
             kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles, kStayFocusedBundleIds,
             kDisableKey, kMouseDelta, kLegacyActivation, kWindowServerHitTest,
             kMenuBarIcon, kLiveReload, kVerbose, kConfig];
}

@implementation ARConfig

// Warping needs both factors, which is how it has always been switched on.
- (BOOL)warpMouse {
    return self.warpX >= 0 && self.warpX <= 1 && self.warpY >= 0 && self.warpY <= 1;
}

- (int)primaryDelayTicks {
    return self.focusDelayTicks ? self.focusDelayTicks : self.delayTicks;
}

- (int)raiseAfterFocusTicks {
    return self.focusDelayTicks ? self.delayTicks : 1;
}

- (BOOL)focusFirst {
    return self.primaryDelayTicks && self.raiseAfterFocusTicks != 1;
}

@end

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

ARConfig *ARConfigFromValues(NSDictionary<NSString *, NSString *> *values,
                             NSArray<NSString *> *warnings) {
    ARConfig *config = [[ARConfig alloc] init];
    NSMutableArray *allWarnings = [(warnings ?: @[]) mutableCopy];

    config.pollMillis = values[kPollMillis] ? [values[kPollMillis] intValue] : 50;
    if (config.pollMillis < AR_MIN_POLL_MILLIS) {
        if (values[kPollMillis]) {
            [allWarnings addObject: [NSString stringWithFormat: @"pollMillis %@ is below the %d minimum, using 50",
                                     values[kPollMillis], AR_MIN_POLL_MILLIS]];
        }
        config.pollMillis = 50;
    }

    config.heartbeatMillis = values[kHeartbeatMillis] ? [values[kHeartbeatMillis] intValue] : 500;
    if (config.heartbeatMillis && config.heartbeatMillis < config.pollMillis) {
        config.heartbeatMillis = config.pollMillis;
    }

    config.delayTicks = [values[kDelay] intValue];
    config.focusDelayTicks = [values[kFocusDelay] intValue];
    if (!values[kDelay] && !values[kFocusDelay]) { config.delayTicks = 1; }
    if (!config.delayTicks && !values[kFocusDelay]) { config.focusDelayTicks = 1; }
    if (!values[kDelay] && !config.focusDelayTicks) { config.delayTicks = 1; }

    config.warpX = values[kWarpX] ? [values[kWarpX] floatValue] : -1;
    config.warpY = values[kWarpY] ? [values[kWarpY] floatValue] : -1;
    config.cursorScale = values[kScale] ? [values[kScale] floatValue] : 2.0;
    if (config.cursorScale < 1) { config.cursorScale = 2.0; }

    config.altTaskSwitcher = ARBool(values, kAltTaskSwitcher, NO);
    config.requireMouseStop = ARBool(values, kRequireMouseStop, YES);
    config.ignoreSpaceChanged = ARBool(values, kIgnoreSpaceChanged, NO);
    config.invertDisableKey = ARBool(values, kInvertDisableKey, NO);
    config.invertIgnoreApps = ARBool(values, kInvertIgnoreApps, NO);
    config.legacyActivation = ARBool(values, kLegacyActivation, NO);
    config.windowServerHitTest = ARBool(values, kWindowServerHitTest, YES);
    config.menuBarIcon = ARBool(values, kMenuBarIcon, YES);
    config.liveReload = ARBool(values, kLiveReload, YES);
    config.verbose = ARBool(values, kVerbose, NO);

    config.mouseDelta = [values[kMouseDelta] floatValue];
    if (config.mouseDelta < 0) { config.mouseDelta = 0; }

    NSString *disableKey = values[kDisableKey] ?: @"control";
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
                @"disableKey \"%@\" is not control, option, command, shift or disabled", disableKey]];
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
            "# How often to re-evaluate while the mouse is moving, in milliseconds.\n"
            "pollMillis=50\n"
            "# Idle safety net for windows that appear under a still cursor. 0 disables.\n"
            "heartbeatMillis=500\n"
            "\n"
            "# Raise delay in evaluations: 0 never raises, 1 raises at once, n waits\n"
            "# (n-1) * pollMillis.\n"
            "delay=1\n"
            "# Focus the hovered window first and raise it after this many evaluations.\n"
            "# 0 disables. Uses private API, see the README.\n"
            "focusDelay=0\n"
            "\n"
            "# Warp the mouse into the window activated by cmd-tab or cmd-grave.\n"
            "# Both factors are between 0 and 1; leave them out to disable warping.\n"
            "#warpX=0.5\n"
            "#warpY=0.1\n"
            "#scale=2.5\n"
            "#altTaskSwitcher=false\n"
            "\n"
            "requireMouseStop=true\n"
            "ignoreSpaceChanged=false\n"
            "mouseDelta=0.0\n"
            "\n"
            "# Hold this key to suspend AutoRaise: control, option, command, shift, disabled.\n"
            "disableKey=control\n"
            "invertDisableKey=false\n"
            "\n"
            "# Apps and window titles to leave alone. App entries match a localized\n"
            "# name or a bundle identifier; titles are ICU regular expressions.\n"
            "# Escape a literal comma as \\,\n"
            "#ignoreApps=\"IntelliJ IDEA,com.jetbrains.WebStorm\"\n"
            "#ignoreTitles=\"^window$\"\n"
            "#invertIgnoreApps=false\n"
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
            "verbose=false\n";
}

NSString *ARConfigUsage(void) {
    return @"AutoRaise\n"
            "  -pollMillis <20, 30, 40, 50, ...>     evaluation interval while moving\n"
            "  -heartbeatMillis <500>                idle safety net, 0 disables\n"
            "  -delay <0=no-raise, 1=no-delay, n>    raise delay in evaluations\n"
            "  -focusDelay <0=no-focus, 1=no-delay>  focus first, raise later\n"
            "  -warpX <0.5> -warpY <0.5> -scale <2.0>\n"
            "  -altTaskSwitcher <true|false>\n"
            "  -requireMouseStop <true|false>\n"
            "  -ignoreSpaceChanged <true|false>\n"
            "  -invertDisableKey <true|false>\n"
            "  -invertIgnoreApps <true|false>\n"
            "  -ignoreApps \"<App1,com.example.app2, ...>\"\n"
            "  -ignoreTitles \"<Regex1,Regex2, ...>\"\n"
            "  -stayFocusedBundleIds \"<Id1,Id2, ...>\"\n"
            "  -disableKey <control|option|command|shift|disabled>\n"
            "  -mouseDelta <0.1>\n"
            "  -windowServerHitTest <true|false>     ask the window server, not the app\n"
            "  -legacyActivation <true|false>        for GTK, SDL and wine apps\n"
            "  -menuBarIcon <true|false>\n"
            "  -liveReload <true|false>\n"
            "  -verbose <true|false>\n"
            "  -config <path>                        use this file instead of the default\n"
            "  -dumpQuirks                           print the built-in app quirks\n"
            "  -probe                                report which window is under the mouse\n"
            "  -help, -version\n";
}

static NSString *ARDescribeDelay(int ticks, int pollMillis) {
    if (!ticks) { return @"disabled"; }
    return [NSString stringWithFormat: @"%dms", (ticks - 1) * pollMillis];
}

NSString *ARConfigSummary(ARConfig *config) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat: @"Settings from %@:\n", config.sourcePath ?: @"defaults and arguments"];
    [out appendFormat: @"  * pollMillis: %dms", config.pollMillis];
    if (config.heartbeatMillis) { [out appendFormat: @", heartbeat: %dms\n", config.heartbeatMillis]; }
    else { [out appendString: @", heartbeat: disabled\n"]; }
    [out appendFormat: @"  * delay: %@\n", ARDescribeDelay(config.delayTicks, config.pollMillis)];
    [out appendFormat: @"  * focusDelay: %@%@\n", ARDescribeDelay(config.focusDelayTicks, config.pollMillis),
        config.focusFirst ? @" (focus first)" : @""];
    if (config.warpMouse) {
        [out appendFormat: @"  * warpX: %.2f, warpY: %.2f, scale: %.1f\n",
            config.warpX, config.warpY, config.cursorScale];
        [out appendFormat: @"  * altTaskSwitcher: %s\n", config.altTaskSwitcher ? "true" : "false"];
    }
    [out appendFormat: @"  * requireMouseStop: %s\n", config.requireMouseStop ? "true" : "false"];
    [out appendFormat: @"  * ignoreSpaceChanged: %s\n", config.ignoreSpaceChanged ? "true" : "false"];
    [out appendFormat: @"  * disableKey: %@%@\n", config.disableKeyName,
        config.invertDisableKey ? @" (inverted)" : @""];
    if (config.mouseDelta) { [out appendFormat: @"  * mouseDelta: %.2f\n", config.mouseDelta]; }
    for (NSString *app in config.ignoreApps) {
        [out appendFormat: @"  * %@: %@\n", config.invertIgnoreApps ? @"includeApp" : @"ignoreApp", app];
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
