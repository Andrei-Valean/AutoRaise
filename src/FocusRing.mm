/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "FocusRing.h"

#import <QuartzCore/QuartzCore.h>

// Room around the window frame for the glow to fade out in.
#define AR_RING_MARGIN 8.0
// macOS window corners, near enough that the ring follows them.
#define AR_RING_RADIUS 11.0
#define AR_PULSE_SECONDS 1.1

@interface ARRingView : NSView
@property (nonatomic) ARColor color;
@end

@implementation ARRingView

- (BOOL)isOpaque { return NO; }
- (NSView *)hitTest:(NSPoint)point { return nil; }   // never in the way

- (NSColor *)strokeColorWithAlpha:(CGFloat)alpha {
    if (_color.followsAccent) {
        return [NSColor.controlAccentColor colorWithAlphaComponent: alpha];
    }
    return [NSColor colorWithSRGBRed: _color.red green: _color.green blue: _color.blue
                               alpha: alpha * _color.alpha];
}

// Three passes: a wide soft glow, a middle band, and one crisp line, so the
// ring reads as a glow rather than a border.
- (void)drawRect:(NSRect)dirty {
    NSRect frame = NSInsetRect(self.bounds, AR_RING_MARGIN, AR_RING_MARGIN);
    const CGFloat widths[] = {7.0, 3.5, 1.5};
    const CGFloat alphas[] = {0.16, 0.34, 0.95};

    for (int i = 0; i < 3; i++) {
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:
            NSInsetRect(frame, -widths[i] / 2, -widths[i] / 2)
            xRadius: AR_RING_RADIUS + widths[i] / 2 yRadius: AR_RING_RADIUS + widths[i] / 2];
        path.lineWidth = widths[i];
        [[self strokeColorWithAlpha: alphas[i]] setStroke];
        [path stroke];
    }
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;   // the accent colour differs per appearance
}

@end

@implementation ARFocusRing {
    NSPanel *_panel;
    ARRingView *_view;
}

- (instancetype)init {
    if ((self = [super init])) {
        _color = ARColorParse(nil, NULL);   // follows the accent colour

        // A non-activating panel: it can never take the keyboard, and it never
        // becomes the window AutoRaise thinks you are hovering, because
        // floating windows are not at layer zero.
        _panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 10, 10)
            styleMask: NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing: NSBackingStoreBuffered defer: NO];
        _panel.opaque = NO;
        _panel.backgroundColor = NSColor.clearColor;
        _panel.hasShadow = NO;
        _panel.ignoresMouseEvents = YES;
        _panel.level = NSFloatingWindowLevel;
        _panel.releasedWhenClosed = NO;
        _panel.hidesOnDeactivate = NO;
        _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorStationary |
                                    NSWindowCollectionBehaviorIgnoresCycle |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
        _panel.accessibilitySubrole = NSAccessibilityUnknownSubrole;

        _view = [[ARRingView alloc] initWithFrame: NSZeroRect];
        _view.wantsLayer = YES;
        _panel.contentView = _view;
    }
    return self;
}

- (void)setColor:(ARColor)color {
    _color = color;
    _view.color = color;
    _view.needsDisplay = YES;
}

- (BOOL)visible { return _panel.isVisible; }

// The accessibility API reports window frames from the top left of the primary
// display; NSWindow wants them from the bottom left.
- (NSRect)panelFrameForWindowFrame:(CGRect)frame {
    NSScreen *primary = NSScreen.screens.firstObject;
    CGFloat top = primary ? NSMaxY(primary.frame) : 0;
    return NSMakeRect(frame.origin.x - AR_RING_MARGIN,
                      top - (frame.origin.y + frame.size.height) - AR_RING_MARGIN,
                      frame.size.width + AR_RING_MARGIN * 2,
                      frame.size.height + AR_RING_MARGIN * 2);
}

- (void)showAroundFrame:(CGRect)frame {
    if (frame.size.width < 1 || frame.size.height < 1) { return; }
    _view.color = _color;
    [_panel setFrame: [self panelFrameForWindowFrame: frame] display: YES];
    _view.needsDisplay = YES;

    if (!_panel.isVisible) {
        [_panel orderFront: nil];
        [self startPulsing];
    }
}

- (void)startPulsing {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath: @"opacity"];
    pulse.fromValue = @0.45;
    pulse.toValue = @1.0;
    pulse.duration = AR_PULSE_SECONDS;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction
        functionWithName: kCAMediaTimingFunctionEaseInEaseOut];
    [_view.layer addAnimation: pulse forKey: @"pulse"];
}

- (void)hide {
    if (!_panel.isVisible) { return; }
    [_view.layer removeAnimationForKey: @"pulse"];
    [_panel orderOut: nil];
}

@end
