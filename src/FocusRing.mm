/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "FocusRing.h"
#import "WindowFinder.h"

#import <QuartzCore/QuartzCore.h>

// How often the ring re-checks what is covering the window it marks. Only while
// it is on screen, and only one call to the window server each time.
#define AR_CLIP_REFRESH_SECONDS 0.4

@interface ARRingView : NSView
@property (nonatomic) ARColor color;
@property (nonatomic) ARRingStyle style;
// Rectangles, in this view's coordinates, that are covered by windows in front
// of the one being outlined. The ring is not drawn inside them.
@property (nonatomic, copy) NSArray<NSValue *> *obscured;
@end

// Room the glow needs outside the window frame to fade out in.
static CGFloat ARRingMargin(ARRingStyle style) {
    if (style.insideFrame) { return 0; }
    return ceil(style.glow + style.width) + 1;
}

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

// The glow is two wide, faint strokes under one crisp line. Outline centres
// them on the window edge so the glow spreads both ways; inline tucks every
// stroke inside the edge.
- (void)strokeWidth:(CGFloat)width alpha:(CGFloat)alpha {
    if (width <= 0) { return; }
    NSRect rect;
    CGFloat radius;
    if (_style.insideFrame) {
        rect = NSInsetRect(self.bounds, width / 2, width / 2);
        radius = fmax(0, _style.radius - width / 2);
    } else {
        CGFloat margin = ARRingMargin(_style);
        rect = NSInsetRect(self.bounds, margin, margin);
        radius = _style.radius;
    }
    if (rect.size.width <= 0 || rect.size.height <= 0) { return; }

    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect: rect
        xRadius: radius yRadius: radius];
    path.lineWidth = width;
    [[self strokeColorWithAlpha: alpha * _style.opacity] setStroke];
    [path stroke];
}

- (void)drawRect:(NSRect)dirty {
    if (_obscured.count) {
        // Even-odd winding turns the outer rectangle plus the covered ones into
        // "everything except the covered parts", which is the visible shape of
        // the window this ring belongs to.
        NSBezierPath *clip = [NSBezierPath bezierPathWithRect: self.bounds];
        for (NSValue *value in _obscured) { [clip appendBezierPathWithRect: value.rectValue]; }
        clip.windingRule = NSWindingRuleEvenOdd;
        [clip setClip];
    }
    if (_style.glow > 0) {
        [self strokeWidth: _style.width + _style.glow * 2 alpha: 0.12];
        [self strokeWidth: _style.width + _style.glow alpha: 0.26];
    }
    [self strokeWidth: _style.width alpha: 0.95];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;   // the accent colour differs per appearance
}

@end

BOOL ARFocusRingVerbose = NO;

@implementation ARFocusRing {
    NSPanel *_panel;
    ARRingView *_view;
    CGWindowID _windowId;
    NSTimer *_clipTimer;
    ARRingStyle _effective;   // the style actually drawn, see below
}

- (instancetype)init {
    if ((self = [super init])) {
        _color = ARColorParse(nil, NULL);   // follows the accent colour
        _style = ARRingStyleDefaults();
        _effective = _style;

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
        // The panel floats above everything, and is then clipped to the part of
        // the window that is actually visible. Ordering it into another
        // application's stacking order is not something the window server
        // allows, so the ring imitates the result instead.
        _panel.level = NSFloatingWindowLevel;
        _panel.releasedWhenClosed = NO;
        _panel.hidesOnDeactivate = NO;
        // Follows to whichever desktop it is shown on, rather than joining all of
        // them: a ring belongs to one window, and turning up on a desktop that
        // window is not on was a bug.
        _panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                    NSWindowCollectionBehaviorIgnoresCycle |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary;
        _panel.accessibilitySubrole = NSAccessibilityUnknownSubrole;

        _view = [[ARRingView alloc] initWithFrame: NSZeroRect];
        _view.wantsLayer = YES;
        _view.style = _style;
        _panel.contentView = _view;
    }
    return self;
}

- (void)setColor:(ARColor)color {
    _color = color;
    _view.color = color;
    _view.needsDisplay = YES;
}

- (void)setStyle:(ARRingStyle)style {
    BOOL pulseChanged = style.pulseSeconds != _style.pulseSeconds;
    _style = style;
    _effective = style;
    _view.style = style;
    _view.needsDisplay = YES;
    if (pulseChanged && _panel.isVisible) { [self startPulsing]; }
}

// A window filling its display leaves no room outside itself, and a ring drawn
// around such a window is entirely off screen. There the ring goes inside the
// window edge instead, whatever the setting says, because an invisible outline
// is worse than one a couple of points further in.
- (ARRingStyle)styleForWindowFrame:(CGRect)frame {
    ARRingStyle style = _style;
    if (style.insideFrame) { return style; }

    CGFloat margin = ARRingMargin(style);
    CGRect wanted = CGRectInset(frame, -margin, -margin);
    CGRect display = CGRectZero;
    CGFloat menuBarHeight = 0;
    CGPoint centre = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    if (ARScreenAtPoint(centre, &display, &menuBarHeight) &&
        !CGRectContainsRect(display, wanted)) {
        style.insideFrame = YES;
        if (ARFocusRingVerbose) {
            NSLog(@"Window fills its display, drawing the ring inside the edge");
        }
    }
    return style;
}

- (BOOL)visible { return _panel.isVisible; }

// The accessibility API reports window frames from the top left of the primary
// display; NSWindow wants them from the bottom left.
- (NSRect)panelFrameForWindowFrame:(CGRect)frame {
    NSScreen *primary = NSScreen.screens.firstObject;
    CGFloat top = primary ? NSMaxY(primary.frame) : 0;
    CGFloat margin = ARRingMargin(_effective);
    return NSMakeRect(frame.origin.x - margin,
                      top - (frame.origin.y + frame.size.height) - margin,
                      frame.size.width + margin * 2,
                      frame.size.height + margin * 2);
}

- (void)showAroundFrame:(CGRect)frame ofWindow:(CGWindowID)windowId {
    if (frame.size.width < 1 || frame.size.height < 1) { return; }

    // Settle the style first: it decides how much room the panel needs around
    // the window, or none at all when the ring has to go inside.
    _effective = [self styleForWindowFrame: frame];
    _view.style = _effective;
    _view.color = _color;
    [_panel setFrame: [self panelFrameForWindowFrame: frame] display: YES];
    _view.needsDisplay = YES;

    BOOL wasVisible = _panel.isVisible;
    _windowId = windowId;
    [self refreshClip];
    if (!wasVisible) {
        [_panel orderFront: nil];
        [self startPulsing];
        _clipTimer = [NSTimer scheduledTimerWithTimeInterval: AR_CLIP_REFRESH_SECONDS
            target: self selector: @selector(clipTimerFired:) userInfo: nil repeats: YES];
        _clipTimer.tolerance = AR_CLIP_REFRESH_SECONDS / 2;
    }
}

- (void)clipTimerFired:(NSTimer *)timer { [self refreshClip]; }

// Works out which parts of the outlined window are hidden behind other windows,
// and hands them to the view in its own coordinates.
- (void)refreshClip {
    NSRect panelFrame = _panel.frame;
    NSScreen *primary = NSScreen.screens.firstObject;
    CGFloat top = primary ? NSMaxY(primary.frame) : 0;

    NSMutableArray<NSValue *> *obscured = [NSMutableArray array];
    for (NSValue *value in ARWindowsInFrontOf(_windowId)) {
        NSRect cg = value.rectValue;
        NSRect screenRect = NSMakeRect(cg.origin.x, top - (cg.origin.y + cg.size.height),
                                       cg.size.width, cg.size.height);
        NSRect overlap = NSIntersectionRect(screenRect, panelFrame);
        if (NSIsEmptyRect(overlap)) { continue; }
        [obscured addObject: [NSValue valueWithRect: NSMakeRect(
            overlap.origin.x - panelFrame.origin.x, overlap.origin.y - panelFrame.origin.y,
            overlap.size.width, overlap.size.height)]];
    }

    if (obscured.count != _view.obscured.count ||
        ![obscured isEqualToArray: _view.obscured]) {
        if (ARFocusRingVerbose) {
            NSLog(@"Ring around window %u: %lu covering rectangles",
                  _windowId, (unsigned long) obscured.count);
        }
        _view.obscured = obscured;
        _view.needsDisplay = YES;
    }
}

// Joins the stacking order just above the window being outlined, so a window in
// front of that one hides the ring as well.


- (void)startPulsing {
    [_view.layer removeAnimationForKey: @"pulse"];
    if (_effective.pulseSeconds <= 0) {
        _view.layer.opacity = 1.0;
        return;
    }
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath: @"opacity"];
    pulse.fromValue = @0.45;
    pulse.toValue = @1.0;
    // One full breath: half in, half out.
    pulse.duration = _effective.pulseSeconds / 2;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction
        functionWithName: kCAMediaTimingFunctionEaseInEaseOut];
    [_view.layer addAnimation: pulse forKey: @"pulse"];
}

- (void)hide {
    [_clipTimer invalidate];
    _clipTimer = nil;
    _windowId = kCGNullWindowID;
    if (!_panel.isVisible) { return; }
    [_view.layer removeAnimationForKey: @"pulse"];
    [_panel orderOut: nil];
}

@end
