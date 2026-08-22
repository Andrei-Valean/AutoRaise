/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Stats: what hovering saved you.
 *
 * Every window AutoRaise focuses or raises on hover is a click you did not make.
 * Counting them is cheap and the numbers are kept in
 * ~/.config/AutoRaise/stats.json, written at most once a minute.
 *
 * The aggregation is separated from the file so tests can drive it directly.
 */

#pragma once

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ARSavedAction) {
    ARSavedActionNone = 0,
    ARSavedActionRaised,    // the window was brought to the front
    ARSavedActionFocused,   // it took the keyboard where it stood
};

// One row of the top applications list.
@interface ARAppTally : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *bundleId;
@property (nonatomic) NSInteger count;
@end

@interface ARStats : NSObject

+ (ARStats *)shared;

// Tests build one of these directly rather than through the file.
- (instancetype)initWithDictionary:(nullable NSDictionary *)saved;
- (NSDictionary *)dictionaryRepresentation;

- (void)recordAction:(ARSavedAction)action
                 app:(nullable NSString *)name
            bundleId:(nullable NSString *)bundleId;
- (void)recordShortcutRaise;
- (void)recordWarpOver:(CGFloat)pixels;
- (void)reset;

// Writes only when something changed, and at most once a minute unless forced.
- (void)flush:(BOOL)force;

@property (nonatomic, readonly) NSInteger clicksSaved;
@property (nonatomic, readonly) NSInteger raises;
@property (nonatomic, readonly) NSInteger focuses;
@property (nonatomic, readonly) NSInteger shortcutRaises;
@property (nonatomic, readonly) NSInteger warps;
@property (nonatomic, readonly) double warpPixels;
@property (nonatomic, readonly, copy) NSDate *since;
@property (nonatomic, readonly) NSInteger today;
@property (nonatomic, readonly) NSInteger busiestDay;

// Oldest first, one entry per day, ending today. Days with nothing are zero.
- (NSArray<NSNumber *> *)countsForLastDays:(NSInteger)days;
- (NSArray<ARAppTally *> *)topApps:(NSInteger)limit;

// For the labels under the chart.
+ (NSString *)shortDayLabelFor:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END
