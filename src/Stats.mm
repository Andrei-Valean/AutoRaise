/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Stats.h"

// Long enough that a busy afternoon of hovering costs one write a minute.
#define AR_STATS_WRITE_INTERVAL 60.0
// A history longer than this is of no interest and would grow without end.
#define AR_STATS_DAYS_KEPT 120

static NSString *const kSince = @"since";
static NSString *const kRaises = @"raises";
static NSString *const kFocuses = @"focuses";
static NSString *const kShortcutRaises = @"shortcutRaises";
static NSString *const kWarps = @"warps";
static NSString *const kWarpPixels = @"warpPixels";
static NSString *const kByDay = @"byDay";
static NSString *const kByApp = @"byApp";
static NSString *const kAppName = @"name";
static NSString *const kAppCount = @"count";

@implementation ARAppTally
@end

@implementation ARStats {
    NSInteger _raises, _focuses, _shortcutRaises, _warps;
    double _warpPixels;
    NSDate *_since;
    NSMutableDictionary<NSString *, NSNumber *> *_byDay;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_byApp;
    BOOL _dirty;
    NSTimeInterval _writtenAt;
}

+ (ARStats *)shared {
    static ARStats *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *saved = [NSData dataWithContentsOfFile: [ARStats path]];
        NSDictionary *parsed = saved ? [NSJSONSerialization JSONObjectWithData: saved
            options: 0 error: nil] : nil;
        shared = [[ARStats alloc] initWithDictionary: parsed];
    });
    return shared;
}

+ (NSString *)path {
    return [NSHomeDirectory() stringByAppendingPathComponent: @".config/AutoRaise/stats.json"];
}

static NSDateFormatter *ARDayFormatter(void) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd";
        formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
    });
    return formatter;
}

- (instancetype)initWithDictionary:(NSDictionary *)saved {
    if ((self = [super init])) {
        _byDay = [NSMutableDictionary dictionary];
        _byApp = [NSMutableDictionary dictionary];
        _since = [NSDate date];

        if ([saved isKindOfClass: [NSDictionary class]]) {
            _raises = [saved[kRaises] integerValue];
            _focuses = [saved[kFocuses] integerValue];
            _shortcutRaises = [saved[kShortcutRaises] integerValue];
            _warps = [saved[kWarps] integerValue];
            _warpPixels = [saved[kWarpPixels] doubleValue];

            NSString *since = saved[kSince];
            NSDate *parsed = [since isKindOfClass: [NSString class]]
                ? [ARDayFormatter() dateFromString: since] : nil;
            if (parsed) { _since = parsed; }

            for (id key in saved[kByDay]) {
                if (![key isKindOfClass: [NSString class]]) { continue; }
                _byDay[key] = @([saved[kByDay][key] integerValue]);
            }
            for (id key in saved[kByApp]) {
                if (![key isKindOfClass: [NSString class]]) { continue; }
                NSDictionary *entry = saved[kByApp][key];
                if (![entry isKindOfClass: [NSDictionary class]]) { continue; }
                _byApp[key] = [@{kAppName: entry[kAppName] ?: key,
                                 kAppCount: @([entry[kAppCount] integerValue])} mutableCopy];
            }
        }
        [self trimHistory];
    }
    return self;
}

- (NSDictionary *)dictionaryRepresentation {
    return @{kSince: [ARDayFormatter() stringFromDate: _since],
             kRaises: @(_raises), kFocuses: @(_focuses),
             kShortcutRaises: @(_shortcutRaises),
             kWarps: @(_warps), kWarpPixels: @(_warpPixels),
             kByDay: [_byDay copy], kByApp: [_byApp copy]};
}

//------------------------------------------------ counting ------------------------------------------------

- (void)recordAction:(ARSavedAction)action app:(NSString *)name bundleId:(NSString *)bundleId {
    if (action == ARSavedActionNone) { return; }
    if (action == ARSavedActionRaised) { _raises++; } else { _focuses++; }
    [self countToday];

    NSString *key = bundleId.length ? bundleId : (name.length ? name : @"unknown");
    NSMutableDictionary *entry = _byApp[key];
    if (!entry) {
        entry = [@{kAppName: name.length ? name : key, kAppCount: @0} mutableCopy];
        _byApp[key] = entry;
    }
    if (name.length) { entry[kAppName] = name; }
    entry[kAppCount] = @([entry[kAppCount] integerValue] + 1);
    _dirty = YES;
}

- (void)recordShortcutRaise {
    _shortcutRaises++;
    [self countToday];
    _dirty = YES;
}

- (void)recordWarpOver:(CGFloat)pixels {
    if (pixels <= 0) { return; }
    _warps++;
    _warpPixels += pixels;
    _dirty = YES;
}

- (void)countToday {
    NSString *key = [ARDayFormatter() stringFromDate: [NSDate date]];
    _byDay[key] = @([_byDay[key] integerValue] + 1);
}

- (void)reset {
    _raises = _focuses = _shortcutRaises = _warps = 0;
    _warpPixels = 0;
    _since = [NSDate date];
    [_byDay removeAllObjects];
    [_byApp removeAllObjects];
    _dirty = YES;
    [self flush: YES];
}

- (void)trimHistory {
    if (_byDay.count <= AR_STATS_DAYS_KEPT) { return; }
    NSArray *keys = [_byDay.allKeys sortedArrayUsingSelector: @selector(compare:)];
    for (NSUInteger i = 0; i + AR_STATS_DAYS_KEPT < keys.count; i++) {
        [_byDay removeObjectForKey: keys[i]];
    }
}

- (void)flush:(BOOL)force {
    if (!_dirty) { return; }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!force && now - _writtenAt < AR_STATS_WRITE_INTERVAL) { return; }

    [self trimHistory];
    NSString *path = [ARStats path];
    NSError *error = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent
        withIntermediateDirectories: YES attributes: nil error: &error];
    NSData *data = [NSJSONSerialization dataWithJSONObject: [self dictionaryRepresentation]
        options: NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error: &error];
    if (!data || ![data writeToFile: path atomically: YES]) {
        NSLog(@"Could not write %@: %@", path, error.localizedDescription);
        return;
    }
    _writtenAt = now;
    _dirty = NO;
}

//------------------------------------------------ reading -------------------------------------------------

- (NSInteger)raises { return _raises; }
- (NSInteger)focuses { return _focuses; }
- (NSInteger)shortcutRaises { return _shortcutRaises; }
- (NSInteger)warps { return _warps; }
- (double)warpPixels { return _warpPixels; }
- (NSDate *)since { return _since; }

- (NSInteger)clicksSaved { return _raises + _focuses + _shortcutRaises; }

- (NSInteger)today {
    return [_byDay[[ARDayFormatter() stringFromDate: [NSDate date]]] integerValue];
}

- (NSInteger)busiestDay {
    NSInteger most = 0;
    for (NSNumber *count in _byDay.allValues) { most = MAX(most, count.integerValue); }
    return most;
}

- (NSArray<NSNumber *> *)countsForLastDays:(NSInteger)days {
    NSMutableArray *counts = [NSMutableArray array];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    NSDate *today = [NSDate date];
    for (NSInteger offset = days - 1; offset >= 0; offset--) {
        NSDate *day = [calendar dateByAddingUnit: NSCalendarUnitDay value: -offset
                                          toDate: today options: 0];
        NSString *key = [ARDayFormatter() stringFromDate: day];
        [counts addObject: @([_byDay[key] integerValue])];
    }
    return counts;
}

- (NSArray<ARAppTally *> *)topApps:(NSInteger)limit {
    NSMutableArray<ARAppTally *> *tallies = [NSMutableArray array];
    for (NSString *key in _byApp) {
        ARAppTally *tally = [[ARAppTally alloc] init];
        tally.bundleId = [key containsString: @"."] ? key : nil;
        tally.name = _byApp[key][kAppName] ?: key;
        tally.count = [_byApp[key][kAppCount] integerValue];
        [tallies addObject: tally];
    }
    [tallies sortUsingComparator: ^NSComparisonResult(ARAppTally *a, ARAppTally *b) {
        if (a.count != b.count) { return a.count > b.count ? NSOrderedAscending : NSOrderedDescending; }
        return [a.name compare: b.name];
    }];
    if ((NSInteger) tallies.count > limit) {
        [tallies removeObjectsInRange: NSMakeRange(limit, tallies.count - limit)];
    }
    return tallies;
}

+ (NSString *)shortDayLabelFor:(NSDate *)date {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"d MMM";
    });
    return [formatter stringFromDate: date];
}

@end
