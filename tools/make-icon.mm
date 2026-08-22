/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Draws AutoRaise.icns from code, so the icon is versioned as a few hundred
 * lines of geometry rather than a binary nobody can edit.
 *
 * The mark: a window card lifting off the one behind it, with a pointer at the
 * corner. Hover, and the window comes forward.
 *
 * Usage: make-icon <output.iconset>   (see the "icon" target in the Makefile)
 */

#import <AppKit/AppKit.h>

// Everything is drawn in a 1024 point square and scaled down from there.
#define CANVAS 1024.0
// macOS app icons leave a margin around the rounded body for the shadow.
#define BODY_INSET 100.0
// The exponent that gives macOS its squircle, rather than a circular corner.
#define SQUIRCLE_EXPONENT 5.0

static CGPathRef CreateSquirclePath(CGRect rect) {
    CGMutablePathRef path = CGPathCreateMutable();
    double a = rect.size.width / 2, b = rect.size.height / 2;
    double cx = CGRectGetMidX(rect), cy = CGRectGetMidY(rect);
    const int steps = 720;
    for (int i = 0; i <= steps; i++) {
        double t = 2 * M_PI * i / steps;
        double c = cos(t), s = sin(t);
        double x = cx + a * copysign(pow(fabs(c), 2.0 / SQUIRCLE_EXPONENT), c);
        double y = cy + b * copysign(pow(fabs(s), 2.0 / SQUIRCLE_EXPONENT), s);
        if (i == 0) { CGPathMoveToPoint(path, NULL, x, y); }
        else { CGPathAddLineToPoint(path, NULL, x, y); }
    }
    CGPathCloseSubpath(path);
    return path;
}

static void DrawGradient(CGContextRef context, CGRect rect,
                         CGFloat from[4], CGFloat to[4], CGPoint start, CGPoint end) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat components[8] = {from[0], from[1], from[2], from[3], to[0], to[1], to[2], to[3]};
    CGFloat locations[2] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, locations, 2);
    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    CGContextDrawLinearGradient(context, gradient,
        CGPointMake(rect.origin.x + start.x * rect.size.width,
                    rect.origin.y + start.y * rect.size.height),
        CGPointMake(rect.origin.x + end.x * rect.size.width,
                    rect.origin.y + end.y * rect.size.height), 0);
    CGContextRestoreGState(context);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

// A rounded rectangle, using the same squircle corners as the body so the cards
// look like they belong to the icon.
static CGPathRef CreateCardPath(CGRect rect, CGFloat radius) {
    return CGPathCreateWithRoundedRect(rect, radius, radius, NULL);
}

// The classic macOS pointer, drawn from a normalised outline (y up).
static CGPathRef CreatePointerPath(CGPoint tip, CGFloat height) {
    static const CGPoint outline[] = {
        {0.000, 1.000}, {0.000, 0.128}, {0.236, 0.356}, {0.379, 0.000},
        {0.548, 0.063}, {0.409, 0.414}, {0.716, 0.437},
    };
    CGFloat scale = height;
    CGMutablePathRef path = CGPathCreateMutable();
    for (size_t i = 0; i < sizeof(outline) / sizeof(outline[0]); i++) {
        CGFloat x = tip.x + outline[i].x * scale;
        CGFloat y = tip.y - (1.0 - outline[i].y) * scale;
        if (i == 0) { CGPathMoveToPoint(path, NULL, x, y); }
        else { CGPathAddLineToPoint(path, NULL, x, y); }
    }
    CGPathCloseSubpath(path);
    return path;
}

static void SetShadow(CGContextRef context, CGSize offset, CGFloat blur, CGFloat alpha) {
    CGColorRef color = CGColorCreateGenericRGB(0.043, 0.055, 0.161, alpha);
    CGContextSetShadowWithColor(context, offset, blur, color);
    CGColorRelease(color);
}

// Blue into violet, plus a soft glow in the top left corner so the gradient has
// some depth. Drawn twice: once for the body, once to carve the gap that keeps
// the two cards apart.
static void FillBody(CGContextRef context, CGRect body) {
    CGFloat top[4] = {0.353, 0.514, 1.000, 1.0};      // #5A83FF
    CGFloat bottom[4] = {0.451, 0.161, 0.918, 1.0};   // #7329EA
    DrawGradient(context, body, top, bottom, CGPointMake(0.1, 1.0), CGPointMake(0.9, 0.0));

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat glow[8] = {1, 1, 1, 0.28, 1, 1, 1, 0};
    CGFloat glowStops[2] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(space, glow, glowStops, 2);
    CGPoint centre = CGPointMake(CGRectGetMinX(body) + 180, CGRectGetMaxY(body) - 120);
    CGContextDrawRadialGradient(context, gradient, centre, 0, centre, 620,
                                kCGGradientDrawsBeforeStartLocation);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

// detail == NO leaves out the pointer and the title bar, which turn to mush
// below 32 points, and grows the cards to fill the space they leave behind.
static void DrawIcon(CGContextRef context, CGFloat size, BOOL detail) {
    CGFloat scale = size / CANVAS;
    CGContextScaleCTM(context, scale, scale);

    CGRect body = CGRectMake(BODY_INSET, BODY_INSET,
                             CANVAS - 2 * BODY_INSET, CANVAS - 2 * BODY_INSET);
    CGPathRef squircle = CreateSquirclePath(body);

    // The body, with the shadow every macOS icon casts.
    CGContextSaveGState(context);
    SetShadow(context, CGSizeMake(0, -18), 44, 0.30);
    CGContextAddPath(context, squircle);
    CGContextSetRGBFillColor(context, 0.35, 0.45, 1.0, 1.0);
    CGContextFillPath(context);
    CGContextRestoreGState(context);

    CGContextSaveGState(context);
    CGContextAddPath(context, squircle);
    CGContextClip(context);
    FillBody(context, body);
    CGContextRestoreGState(context);

    // The cards grow when the fine detail is dropped, so the mark keeps its
    // weight at 16 and 32 points.
    CGFloat grow = detail ? 0 : 8;
    CGRect backCard = CGRectInset(CGRectMake(276, 452, 404, 292), -grow, -grow);
    CGRect frontCard = CGRectInset(CGRectMake(344, 288, 448, 330), -grow, -grow);

    // The window behind: still there, just no longer in front.
    CGPathRef back = CreateCardPath(backCard, 44 + grow / 2);
    CGContextSaveGState(context);
    CGContextAddPath(context, back);
    CGContextSetRGBFillColor(context, 1, 1, 1, detail ? 0.34 : 0.52);
    CGContextFillPath(context);
    CGContextAddPath(context, back);
    CGContextSetRGBStrokeColor(context, 1, 1, 1, detail ? 0.62 : 0.9);
    CGContextSetLineWidth(context, detail ? 10 : 18);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);
    CGPathRelease(back);

    // Carve a gap around the front card by painting the background back in, so
    // the two cards stay separate without leaning on the shadow.
    CGFloat gap = detail ? 20 : 38;
    CGPathRef gapPath = CreateCardPath(CGRectInset(frontCard, -gap, -gap), 52 + gap + grow / 2);
    CGContextSaveGState(context);
    CGContextAddPath(context, squircle);
    CGContextClip(context);
    CGContextAddPath(context, gapPath);
    CGContextClip(context);
    FillBody(context, body);
    CGContextRestoreGState(context);
    CGPathRelease(gapPath);

    // The window that just came forward.
    CGPathRef front = CreateCardPath(frontCard, 52 + grow / 2);
    CGContextSaveGState(context);
    SetShadow(context, CGSizeMake(-8, 26), 46, 0.42);
    CGContextAddPath(context, front);
    CGContextSetRGBFillColor(context, 1, 1, 1, 1);
    CGContextFillPath(context);
    CGContextRestoreGState(context);

    if (detail) {
        // A title bar, so the card reads as a window rather than a rectangle.
        CGContextSaveGState(context);
        CGContextAddPath(context, front);
        CGContextClip(context);
        CGContextSetRGBFillColor(context, 0.353, 0.514, 1.000, 0.16);
        CGContextFillRect(context, CGRectMake(frontCard.origin.x,
            CGRectGetMaxY(frontCard) - 74, frontCard.size.width, 74));
        CGContextSetRGBFillColor(context, 0.451, 0.161, 0.918, 0.42);
        for (int i = 0; i < 3; i++) {
            CGContextFillEllipseInRect(context, CGRectMake(
                frontCard.origin.x + 36 + i * 44, CGRectGetMaxY(frontCard) - 55, 26, 26));
        }
        CGContextRestoreGState(context);
    }
    CGPathRelease(front);

    if (detail) {
        // The pointer that did the raising.
        CGPathRef pointer = CreatePointerPath(CGPointMake(598, 524), 202);
        CGContextSaveGState(context);
        SetShadow(context, CGSizeMake(0, -8), 18, 0.28);
        CGContextAddPath(context, pointer);
        CGContextSetRGBFillColor(context, 0.176, 0.196, 0.427, 1.0);
        CGContextFillPath(context);
        CGContextRestoreGState(context);
        CGPathRelease(pointer);
    }

    // An inner highlight along the top edge, the way glass catches light.
    CGContextSaveGState(context);
    CGContextAddPath(context, squircle);
    CGContextClip(context);
    CGContextAddPath(context, squircle);
    CGContextSetRGBStrokeColor(context, 1, 1, 1, 0.32);
    CGContextSetLineWidth(context, 6);
    CGContextStrokePath(context);
    CGContextRestoreGState(context);

    CGPathRelease(squircle);
}

static BOOL WritePNG(NSString *path, CGFloat size, BOOL detail) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes: NULL pixelsWide: (NSInteger) size pixelsHigh: (NSInteger) size
        bitsPerSample: 8 samplesPerPixel: 4 hasAlpha: YES isPlanar: NO
        colorSpaceName: NSDeviceRGBColorSpace bytesPerRow: 0 bitsPerPixel: 0];

    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithBitmapImageRep: rep];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext: graphics];
    CGContextRef context = graphics.CGContext;
    CGContextSetAllowsAntialiasing(context, true);
    CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
    DrawIcon(context, size, detail);
    [NSGraphicsContext restoreGraphicsState];

    NSData *png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
    return [png writeToFile: path atomically: YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: make-icon <output.iconset>\n");
            return 1;
        }
        NSString *directory = [NSString stringWithUTF8String: argv[1]];
        NSFileManager *files = [NSFileManager defaultManager];
        [files removeItemAtPath: directory error: nil];
        NSError *error = nil;
        if (![files createDirectoryAtPath: directory
                withIntermediateDirectories: YES attributes: nil error: &error]) {
            fprintf(stderr, "cannot create %s: %s\n", argv[1], error.localizedDescription.UTF8String);
            return 1;
        }

        // Every size iconutil wants, each drawn from the vector rather than
        // resampled, so the small ones stay sharp.
        NSArray *variants = @[@[@"icon_16x16.png", @16], @[@"icon_16x16@2x.png", @32],
                              @[@"icon_32x32.png", @32], @[@"icon_32x32@2x.png", @64],
                              @[@"icon_128x128.png", @128], @[@"icon_128x128@2x.png", @256],
                              @[@"icon_256x256.png", @256], @[@"icon_256x256@2x.png", @512],
                              @[@"icon_512x512.png", @512], @[@"icon_512x512@2x.png", @1024]];

        for (NSArray *variant in variants) {
            CGFloat size = [variant[1] doubleValue];
            NSString *path = [directory stringByAppendingPathComponent: variant[0]];
            if (!WritePNG(path, size, size >= 64)) {
                fprintf(stderr, "cannot write %s\n", path.UTF8String);
                return 1;
            }
        }
        printf("Wrote %lu images to %s\n", (unsigned long) variants.count, argv[1]);
    }
    return 0;
}
