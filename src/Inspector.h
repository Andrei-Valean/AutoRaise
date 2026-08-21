/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Inspector: what AutoRaise is thinking, while it thinks it.
 *
 * Everything AutoRaise does is one decision about one window, made from a dozen
 * rules that can each veto. When the answer surprises you, the only way to find
 * out why used to be -verbose and a terminal, which means restarting it under a
 * shell and reading a log next to the thing you were trying to watch.
 *
 * This is that log, live, in a small panel: the window under the pointer, what
 * AutoRaise decided, and every rule that had a say, ending with the one that
 * settled it. The panel never takes the keyboard and never becomes the window
 * under the pointer, so watching does not change what is being watched.
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ARInspector : NSObject

@property (nonatomic, readonly) BOOL visible;

- (void)show;
- (void)hide;
- (void)toggle;

// Called after every evaluation while the panel is up. Identical content is
// dropped rather than redrawn, so a still pointer costs nothing.
- (void)updateWithWindow:(nullable NSString *)window
                     app:(nullable NSString *)app
                 summary:(NSString *)summary
                   trace:(NSArray<NSString *> *)trace
                   facts:(NSArray<NSString *> *)facts;

@end

NS_ASSUME_NONNULL_END
