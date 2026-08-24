/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * AppTable: one place that says how each application should be treated.
 *
 * This replaces a pile of overlapping lists that grew one at a time, each added
 * when somebody hit a case: ignoreApps, invertIgnoreApps, stayFocusedBundleIds
 * and selfRaisingApps. They all answered the same question in different words.
 *
 * It also learns. AutoRaise can watch what an application does in response to
 * being focused or activated, and write that down, instead of asking a person to
 * know it in advance. Learned rows are kept apart from the ones you wrote and
 * can be thrown away without touching your own.
 */

#pragma once

#import <Foundation/Foundation.h>

#import "Policy.h"

NS_ASSUME_NONNULL_BEGIN

// The row that answers for every application no other row names.
#define AR_APP_TABLE_WILDCARD @"*"



// What AutoRaise noticed about an application by watching it.
typedef struct {
    BOOL raisesItself;              // came forward the moment it was focused
    BOOL raisesOnActivate;          // came forward even when focused quietly
    BOOL needsLegacyActivation;     // ignored the modern way of being activated
} ARAppTraits;

@interface ARAppRule : NSObject
@property (nonatomic, copy) NSString *match;      // a localized name or a bundle identifier
@property (nonatomic) ARAppPolicy policy;
@property (nonatomic) ARAppTraits traits;
@property (nonatomic) BOOL learned;               // AutoRaise wrote this, not you
@end

@interface ARAppTable : NSObject

+ (ARAppTable *)shared;
+ (NSString *)path;      // ~/.config/AutoRaise/apps.json

// Tests build one directly rather than through the file.
- (instancetype)initWithRules:(nullable NSArray<ARAppRule *> *)rules;

@property (nonatomic, readonly, copy) NSArray<ARAppRule *> *rules;

// The row that decides for this window: the one naming it, or the catch-all.
- (nullable ARAppRule *)ruleFor:(ARWindow *)window;
- (nullable ARAppRule *)exactRuleFor:(ARWindow *)window;   // never the catch-all
- (nullable ARAppRule *)ruleForMatch:(NSString *)match;
- (ARAppPolicy)policyFor:(ARWindow *)window;
- (ARAppTraits)traitsFor:(ARWindow *)window;

// Written down the first time it is seen, and only then, so the file does not
// churn and the log says it once.
- (BOOL)noteRaisesItself:(ARWindow *)window;
// The quiet treatment was applied and the window rose anyway: this application
// raises itself on mere activation, and the only treatment left is skipping it.
- (BOOL)noteRaisesOnActivate:(ARWindow *)window;
- (BOOL)noteNeedsLegacyActivation:(ARWindow *)window;

- (void)setPolicy:(ARAppPolicy)policy for:(NSString *)match;
- (void)removeRuleFor:(NSString *)match;
- (void)forgetLearned;

// Everything the settings file used to say, folded in on first run so nobody has
// to move their own lists by hand.
- (void)adoptLists:(NSArray<NSString *> *)ignoreApps
          inverted:(BOOL)inverted
        keepFocus:(NSArray<NSString *> *)keepFocus;

// Only the shared table writes a file; one built by hand keeps to itself.
- (void)persist;
- (void)flush;

@end

NS_ASSUME_NONNULL_END
