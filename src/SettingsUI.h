/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * SettingsUI: the building blocks the settings window is assembled from.
 *
 * One visual language, defined once: grouped cards of rows, a label on the
 * left, a control on the right, an explanation underneath. Everything uses
 * semantic colors, so light and dark come for free.
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AR_CARD_RADIUS 10.0
#define AR_ROW_INSET 16.0
#define AR_ROW_HEIGHT 44.0
#define AR_CONTENT_WIDTH 560.0

// Typography, so no size or weight is invented twice.
NSFont *ARTitleFont(void);        // pane title
NSFont *ARRowFont(void);          // row label
NSFont *ARSubtitleFont(void);     // second line of a row
NSFont *ARFootnoteFont(void);     // explanation under a card
NSFont *ARValueFont(void);        // numbers, monospaced digits so they stop jittering

NSTextField *ARLabel(NSString *text, NSFont *font, NSColor *color);

// A container whose origin is the top left, so scrolling to the top is simply
// scrolling to zero.
@interface ARFlippedView : NSView
@end

// A filled, optionally outlined rounded rectangle.
//
// It keeps the colors as NSColor and resolves them during the view update pass,
// because a CGColor is a snapshot: assign one outside a drawing context and the
// shape keeps whichever appearance happened to be current, which is how cards
// end up dark in light mode.
@interface ARFillView : NSView
@property (nonatomic, strong, nullable) NSColor *fillColor;
@property (nonatomic, strong, nullable) NSColor *strokeColor;
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) CGFloat borderWidth;
@end

// A rounded group of rows with hairlines between them.
@interface ARCard : ARFillView
+ (instancetype)cardWithRows:(NSArray<NSView *> *)rows;
- (void)setRows:(NSArray<NSView *> *)rows;
@end

// Label, optional second line, and a control on the right.
@interface ARRow : NSView
@property (nonatomic, readonly) NSTextField *titleLabel;
@property (nonatomic, readonly, nullable) NSTextField *subtitleLabel;
@property (nonatomic, readonly, nullable) NSView *accessory;
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                    accessory:(nullable NSView *)accessory;
// Dependent rows dim instead of disappearing, so the layout never jumps.
- (void)setRowEnabled:(BOOL)enabled;
@end

@interface ARToggleRow : ARRow
@property (nonatomic, readonly) NSSwitch *toggle;
@property (nonatomic, copy, nullable) void (^onChange)(BOOL on);
- (instancetype)initWithTitle:(NSString *)title subtitle:(nullable NSString *)subtitle on:(BOOL)on;
- (void)setOn:(BOOL)on;
@end

// Title and the current value on one line, the slider filling the row below.
// The value text is a sentence, not a number: "Raise after 100 ms".
@interface ARSliderRow : NSView
@property (nonatomic, readonly) NSSlider *slider;
@property (nonatomic, copy, nullable) NSString *(^format)(double value);
@property (nonatomic, copy, nullable) void (^onChange)(double value);
@property (nonatomic, copy, nullable) void (^onCommit)(double value);
// Snap to whole numbers without drawing a comb of tick marks across the track.
@property (nonatomic) BOOL snapsToIntegers;
- (instancetype)initWithTitle:(NSString *)title
                          min:(double)min
                          max:(double)max
                        value:(double)value;
- (void)setValue:(double)value;
- (void)setRowEnabled:(BOOL)enabled;
@end

@interface ARSegmentRow : ARRow
@property (nonatomic, readonly) NSSegmentedControl *segments;
@property (nonatomic, copy, nullable) void (^onChange)(NSInteger index);
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                      choices:(NSArray<NSString *> *)choices
                     selected:(NSInteger)selected;
- (void)setSelected:(NSInteger)index;
@end

@interface ARFieldRow : ARRow
@property (nonatomic, readonly) NSTextField *field;
@property (nonatomic, copy, nullable) void (^onChange)(NSString *text);
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                        value:(NSString *)value
                        width:(CGFloat)width
                  placeholder:(nullable NSString *)placeholder;
@end

@interface ARButtonRow : ARRow
- (instancetype)initWithTitle:(NSString *)title
                     subtitle:(nullable NSString *)subtitle
                  buttonTitle:(NSString *)buttonTitle
                       action:(void (^)(void))action;
@end

// A list of app names, bundle identifiers or patterns, with a plus that can
// browse for applications instead of making people type localized names.
@interface ARListEditor : NSView
@property (nonatomic, copy) NSArray<NSString *> *entries;
@property (nonatomic, copy, nullable) void (^onChange)(NSArray<NSString *> *entries);
@property (nonatomic, copy) NSString *placeholder;
- (instancetype)initWithEntries:(NSArray<NSString *> *)entries
                    allowsApps:(BOOL)allowsApps      // show "Choose App…"
                   bundleIdMode:(BOOL)bundleIdMode;  // store bundle ids, not names
@end

// Where in a window the pointer lands after a task switch, dragged around a
// little window mock rather than typed as two numbers.
@interface ARWarpTargetView : NSView
@property (nonatomic) CGPoint target;    // 0..1 in both directions
@property (nonatomic, copy, nullable) void (^onChange)(CGPoint target);
@end

// Click, then press the combination you want.
@interface ARShortcutField : NSButton
@property (nonatomic, copy, nullable) NSString *shortcut;   // "control-option-A" or nil
@property (nonatomic, copy, nullable) void (^onChange)(NSString *_Nullable shortcut);
@end

// The banner at the top of a pane when something needs attention.
@interface ARNoticeView : ARFillView
- (instancetype)initWithSymbol:(NSString *)symbol
                         tint:(NSColor *)tint
                        title:(NSString *)title
                      message:(NSString *)message
                  buttonTitle:(nullable NSString *)buttonTitle
                       action:(nullable void (^)(void))action;
@end

NS_ASSUME_NONNULL_END
