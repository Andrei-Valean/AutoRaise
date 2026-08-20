/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Quirks.h"

static NSString *const kMainWindowAppsWithoutTitle = @"mainWindowAppsWithoutTitle";
static NSString *const kPwaBrowsers = @"pwaBrowsers";
static NSString *const kAppsRaisingOnFocus = @"appsRaisingOnFocus";
static NSString *const kIgnoreTitles = @"ignoreTitles";
static NSString *const kIgnoreApps = @"ignoreApps";
static NSString *const kFinderApps = @"finderApps";
static NSString *const kTitlesNeedingMainWindowCheck = @"titlesNeedingMainWindowCheck";
static NSString *const kReplaceDefaults = @"replaceDefaults";

static NSArray<NSString *> *ARQuirkKeys(void) {
    return @[kMainWindowAppsWithoutTitle, kPwaBrowsers, kAppsRaisingOnFocus,
             kIgnoreTitles, kIgnoreApps, kFinderApps, kTitlesNeedingMainWindowCheck];
}

ARQuirks *ARQuirksDefaults(void) {
    ARQuirks *quirks = [[ARQuirks alloc] init];

    // Apps whose main window reports no title at all.
    quirks.mainWindowAppsWithoutTitle = @[
        @"System Settings", @"System Information", @"Photos", @"Calculator",
        @"Podcasts", @"Stickies Pro", @"Reeder"
    ];

    // Browsers that host progressive web apps, matched against the third
    // component of bundle identifiers like com.google.Chrome.app.<hash>.
    quirks.pwaBrowsers = @[
        @"Chrome", @"Chromium", @"Vivaldi", @"Brave", @"Opera", @"edgemac", @"helium"
    ];

    // Apps that raise themselves the moment they are focused, so focus-first has
    // nothing left to do for them.
    quirks.appsRaisingOnFocus = @[@"IntelliJ IDEA", @"PyCharm", @"WebStorm", @"Arc", @"Dia"];

    // Windows that look raisable but are menu bar or search overlays.
    quirks.ignoreTitles = @[@"Bartender Bar", @"Zim", @"Search results"];

    // The accessibility helper window macOS shows over everything.
    quirks.ignoreApps = @[@"AssistiveControl"];

    quirks.finderApps = @[@"Finder", @"com.apple.finder"];

    // An empty title, or Mail's search window, mean "check whether this really
    // is a main window" rather than "skip".
    quirks.titlesNeedingMainWindowCheck = @[@"", @"Untitled"];

    return quirks;
}

NSString *ARQuirksUserFilePath(void) {
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *candidate in @[@".config/AutoRaise/quirks.json", @".AutoRaise.quirks.json"]) {
        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent: candidate];
        if ([files fileExistsAtPath: path]) { return path; }
    }
    return nil;
}

static NSError *ARQuirksError(NSString *message) {
    return [NSError errorWithDomain: @"AutoRaise.Quirks" code: 1
                          userInfo: @{NSLocalizedDescriptionKey: message}];
}

static NSArray<NSString *> *ARStringArray(id value, NSString *key, NSError **error) {
    if (![value isKindOfClass: [NSArray class]]) {
        if (error) { *error = ARQuirksError([NSString stringWithFormat: @"\"%@\" must be a list of strings", key]); }
        return nil;
    }
    for (id entry in value) {
        if (![entry isKindOfClass: [NSString class]]) {
            if (error) { *error = ARQuirksError([NSString stringWithFormat: @"\"%@\" must contain strings only", key]); }
            return nil;
        }
    }
    return value;
}

ARQuirks *ARQuirksApplyOverrides(ARQuirks *base, NSDictionary *overrides, NSError **error) {
    if (![overrides isKindOfClass: [NSDictionary class]]) {
        if (error) { *error = ARQuirksError(@"expected a JSON object at the top level"); }
        return base;
    }

    NSArray<NSString *> *known = ARQuirkKeys();
    for (NSString *key in overrides) {
        if ([key isEqualToString: kReplaceDefaults]) { continue; }
        // JSON has no comments, so keys starting with // are treated as one.
        if ([key hasPrefix: @"//"]) { continue; }
        if (![known containsObject: key]) {
            if (error) {
                *error = ARQuirksError([NSString stringWithFormat: @"unknown key \"%@\", expected one of %@",
                                        key, [known componentsJoinedByString: @", "]]);
            }
            return base;
        }
    }

    BOOL replace = [overrides[kReplaceDefaults] boolValue];
    ARQuirks *merged = [[ARQuirks alloc] init];
    for (NSString *key in known) {
        NSArray<NSString *> *defaults = [base valueForKey: key];
        id value = overrides[key];
        if (!value) {
            [merged setValue: (replace ? @[] : defaults) forKey: key];
            continue;
        }
        NSArray<NSString *> *entries = ARStringArray(value, key, error);
        if (!entries) { return base; }
        if (replace) {
            [merged setValue: entries forKey: key];
        } else {
            NSMutableArray *combined = [defaults mutableCopy];
            for (NSString *entry in entries) {
                if (![combined containsObject: entry]) { [combined addObject: entry]; }
            }
            [merged setValue: [combined copy] forKey: key];
        }
    }
    return merged;
}

ARQuirks *ARQuirksLoad(NSString *path, NSError **error) {
    ARQuirks *defaults = ARQuirksDefaults();
    if (!path) { return defaults; }

    NSData *data = [NSData dataWithContentsOfFile: path];
    if (!data) {
        if (error) { *error = ARQuirksError([NSString stringWithFormat: @"cannot read %@", path]); }
        return defaults;
    }

    NSError *jsonError = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData: data options: 0 error: &jsonError];
    if (!parsed) {
        if (error) { *error = jsonError; }
        return defaults;
    }

    return ARQuirksApplyOverrides(defaults, parsed, error);
}

NSString *ARQuirksJSON(ARQuirks *quirks) {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    for (NSString *key in ARQuirkKeys()) { dict[key] = [quirks valueForKey: key]; }
    NSData *data = [NSJSONSerialization dataWithJSONObject: dict
        options: NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error: nil];
    return [[NSString alloc] initWithData: data encoding: NSUTF8StringEncoding];
}
