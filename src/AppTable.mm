/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "AppTable.h"

static NSString *const kMatch = @"app";
static NSString *const kPolicy = @"policy";
static NSString *const kLearned = @"learned";
static NSString *const kRaisesItself = @"raisesItself";
static NSString *const kRaisesOnActivate = @"raisesOnActivate";
static NSString *const kNeedsLegacyActivation = @"needsLegacyActivation";

@implementation ARAppRule
@end

@implementation ARAppTable {
    NSMutableArray<ARAppRule *> *_rules;
    BOOL _dirty;
    BOOL _persists;   // only the one the app uses writes a file
}

+ (ARAppTable *)shared {
    static ARAppTable *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *saved = [NSData dataWithContentsOfFile: [ARAppTable path]];
        NSArray *parsed = saved ? [NSJSONSerialization JSONObjectWithData: saved
            options: 0 error: nil] : nil;
        shared = [[ARAppTable alloc] initWithRules: [ARAppTable rulesFromArray: parsed]];
        [shared persist];
    });
    return shared;
}

+ (NSString *)path {
    return [NSHomeDirectory() stringByAppendingPathComponent: @".config/AutoRaise/apps.json"];
}

+ (NSArray<ARAppRule *> *)rulesFromArray:(NSArray *)saved {
    NSMutableArray<ARAppRule *> *rules = [NSMutableArray array];
    if (![saved isKindOfClass: [NSArray class]]) { return rules; }
    for (NSDictionary *entry in saved) {
        if (![entry isKindOfClass: [NSDictionary class]]) { continue; }
        NSString *match = entry[kMatch];
        if (![match isKindOfClass: [NSString class]] || !match.length) { continue; }

        ARAppRule *rule = [[ARAppRule alloc] init];
        rule.match = match;
        ARAppPolicy policy = ARAppPolicyDefault;
        ARAppPolicyParse(entry[kPolicy], &policy);
        rule.policy = policy;
        rule.learned = [entry[kLearned] boolValue];
        rule.traits = (ARAppTraits) {[entry[kRaisesItself] boolValue],
                                     [entry[kRaisesOnActivate] boolValue],
                                     [entry[kNeedsLegacyActivation] boolValue]};
        [rules addObject: rule];
    }
    return rules;
}

- (instancetype)initWithRules:(NSArray<ARAppRule *> *)rules {
    if ((self = [super init])) {
        _rules = [rules mutableCopy] ?: [NSMutableArray array];
    }
    return self;
}

- (NSArray<ARAppRule *> *)rules { return [_rules copy]; }

// A table built by hand, in a test or a diagnostic, keeps to itself.
- (void)persist { _persists = YES; }

//------------------------------------------------ matching ------------------------------------------------

// An entry matches a localized name or a bundle identifier, the same rule the
// old lists used, so anything anybody had written keeps working. A row for *
// answers for everything nobody named, which is how "only these applications"
// is written down.
- (ARAppRule *)exactRuleFor:(ARWindow *)window {
    for (ARAppRule *rule in _rules) {
        if ([rule.match isEqualToString: AR_APP_TABLE_WILDCARD]) { continue; }
        if (window.appName && [window.appName isEqualToString: rule.match]) { return rule; }
        if (window.bundleId &&
            [window.bundleId caseInsensitiveCompare: rule.match] == NSOrderedSame) {
            return rule;
        }
    }
    return nil;
}

- (ARAppRule *)ruleFor:(ARWindow *)window {
    return [self exactRuleFor: window] ?: [self ruleForMatch: AR_APP_TABLE_WILDCARD];
}

// A row saying "default" has no opinion, so the question passes to the catch-all
// and from there to the general settings. Rows AutoRaise wrote for itself are
// exactly that: traits, no opinion.
- (ARAppPolicy)policyFor:(ARWindow *)window {
    ARAppRule *named = [self exactRuleFor: window];
    if (named && named.policy != ARAppPolicyDefault) { return named.policy; }
    return [self ruleForMatch: AR_APP_TABLE_WILDCARD].policy;
}

// Traits belong to one application, never to the catch-all.
- (ARAppTraits)traitsFor:(ARWindow *)window {
    ARAppRule *rule = [self exactRuleFor: window];
    return rule ? rule.traits : (ARAppTraits) {NO, NO, NO};
}

- (ARAppRule *)ruleForWriting:(ARWindow *)window {
    ARAppRule *rule = [self exactRuleFor: window];
    if (rule) { return rule; }

    rule = [[ARAppRule alloc] init];
    // A bundle identifier keeps working in other languages, so prefer it.
    rule.match = window.bundleId.length ? window.bundleId : (window.appName ?: @"");
    rule.learned = YES;
    if (!rule.match.length) { return nil; }
    [_rules addObject: rule];
    return rule;
}

//------------------------------------------------ learning ------------------------------------------------

- (BOOL)noteRaisesItself:(ARWindow *)window {
    ARAppRule *rule = [self ruleForWriting: window];
    if (!rule || rule.traits.raisesItself) { return NO; }
    ARAppTraits traits = rule.traits;
    traits.raisesItself = YES;
    rule.traits = traits;
    _dirty = YES;
    [self flush];
    return YES;
}

- (BOOL)noteRaisesOnActivate:(ARWindow *)window {
    ARAppRule *rule = [self ruleForWriting: window];
    if (!rule || rule.traits.raisesOnActivate) { return NO; }
    ARAppTraits traits = rule.traits;
    traits.raisesItself = YES;
    traits.raisesOnActivate = YES;
    rule.traits = traits;
    _dirty = YES;
    [self flush];
    return YES;
}

- (BOOL)noteNeedsLegacyActivation:(ARWindow *)window {
    ARAppRule *rule = [self ruleForWriting: window];
    if (!rule || rule.traits.needsLegacyActivation) { return NO; }
    ARAppTraits traits = rule.traits;
    traits.needsLegacyActivation = YES;
    rule.traits = traits;
    _dirty = YES;
    [self flush];
    return YES;
}

//------------------------------------------------ editing -------------------------------------------------

- (void)setPolicy:(ARAppPolicy)policy for:(NSString *)match {
    if (!match.length) { return; }
    for (ARAppRule *rule in _rules) {
        if ([rule.match caseInsensitiveCompare: match] == NSOrderedSame) {
            rule.policy = policy;
            rule.learned = NO;   // a person has had an opinion about it now
            _dirty = YES;
            [self flush];
            return;
        }
    }
    ARAppRule *rule = [[ARAppRule alloc] init];
    rule.match = match;
    rule.policy = policy;
    [_rules addObject: rule];
    _dirty = YES;
    [self flush];
}

- (void)removeRuleFor:(NSString *)match {
    NSUInteger before = _rules.count;
    NSPredicate *keep = [NSPredicate predicateWithBlock:
        ^BOOL(ARAppRule *rule, NSDictionary *bindings) {
            return [rule.match caseInsensitiveCompare: match] != NSOrderedSame;
        }];
    [_rules filterUsingPredicate: keep];
    if (_rules.count != before) { _dirty = YES; [self flush]; }
}

- (void)forgetLearned {
    NSUInteger before = _rules.count;
    // A row somebody wrote stays, even if AutoRaise also learned something about
    // that application; only the traits go.
    NSMutableArray *keep = [NSMutableArray array];
    for (ARAppRule *rule in _rules) {
        if (rule.learned) { continue; }
        rule.traits = (ARAppTraits) {NO, NO};
        [keep addObject: rule];
    }
    _rules = keep;
    if (_rules.count != before) { _dirty = YES; }
    [self flush];
}

// Run once, when a settings file still carries the old lists.
- (void)adoptLists:(NSArray<NSString *> *)ignoreApps
          inverted:(BOOL)inverted
        keepFocus:(NSArray<NSString *> *)keepFocus {
    // Inverted, the list named the only applications to act on: everything in it
    // raises, and one catch-all row leaves the rest alone.
    if (inverted && ignoreApps.count && ![self ruleForMatch: AR_APP_TABLE_WILDCARD]) {
        [self setPolicy: ARAppPolicyIgnore for: AR_APP_TABLE_WILDCARD];
    }
    for (NSString *app in ignoreApps) {
        if (![self ruleForMatch: app]) {
            [self setPolicy: inverted ? ARAppPolicyRaise : ARAppPolicyIgnore for: app];
        }
    }
    for (NSString *app in keepFocus) {
        if (![self ruleForMatch: app]) { [self setPolicy: ARAppPolicyKeepFocus for: app]; }
    }
}

- (ARAppRule *)ruleForMatch:(NSString *)match {
    for (ARAppRule *rule in _rules) {
        if ([rule.match caseInsensitiveCompare: match] == NSOrderedSame) { return rule; }
    }
    return nil;
}

//------------------------------------------------ writing -------------------------------------------------

- (void)flush {
    if (!_dirty || !_persists) { return; }
    NSMutableArray *out = [NSMutableArray array];
    for (ARAppRule *rule in _rules) {
        NSMutableDictionary *entry = [@{kMatch: rule.match,
                                        kPolicy: ARAppPolicyDescribe(rule.policy)} mutableCopy];
        if (rule.learned) { entry[kLearned] = @YES; }
        if (rule.traits.raisesItself) { entry[kRaisesItself] = @YES; }
        if (rule.traits.raisesOnActivate) { entry[kRaisesOnActivate] = @YES; }
        if (rule.traits.needsLegacyActivation) { entry[kNeedsLegacyActivation] = @YES; }
        [out addObject: entry];
    }

    NSString *path = [ARAppTable path];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent
        withIntermediateDirectories: YES attributes: nil error: &error];
    NSData *data = [NSJSONSerialization dataWithJSONObject: out
        options: NSJSONWritingPrettyPrinted error: &error];
    if (!data || ![data writeToFile: path atomically: YES]) {
        NSLog(@"Could not write %@: %@", path, error.localizedDescription);
        return;
    }
    _dirty = NO;
}

@end

