/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "Inspector.h"

#import "SettingsUI.h"

#define AR_INSPECTOR_WIDTH 330.0
#define AR_INSPECTOR_MARGIN 14.0

@implementation ARInspector {
    NSPanel *_panel;
    NSTextField *_windowLabel;
    NSTextField *_appLabel;
    NSTextField *_summaryLabel;
    NSTextField *_traceLabel;
    NSTextField *_factsLabel;
    NSString *_lastContent;
}

- (BOOL)visible { return _panel.isVisible; }

- (void)build {
    if (_panel) { return; }

    // Non-activating so clicking it does not steal the keyboard, and above
    // ordinary windows so it is readable while hovering them. It sits on every
    // space, because the thing being explained happens on all of them.
    _panel = [[NSPanel alloc] initWithContentRect:
                  NSMakeRect(0, 0, AR_INSPECTOR_WIDTH, 200)
              styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                         NSWindowStyleMaskUtilityWindow | NSWindowStyleMaskNonactivatingPanel
              backing: NSBackingStoreBuffered defer: NO];
    _panel.title = @"What AutoRaise is doing";
    _panel.level = NSFloatingWindowLevel;
    _panel.hidesOnDeactivate = NO;
    _panel.becomesKeyOnlyIfNeeded = YES;
    _panel.movableByWindowBackground = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                                NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.releasedWhenClosed = NO;

    _windowLabel = ARLabel(@"Waiting for a hover",
                           [NSFont systemFontOfSize: 13 weight: NSFontWeightSemibold],
                           NSColor.labelColor);
    _appLabel = ARLabel(@"", ARSubtitleFont(), NSColor.secondaryLabelColor);
    _summaryLabel = ARLabel(@"Nothing yet", ARRowFont(), NSColor.labelColor);
    _traceLabel = ARLabel(@"", ARSubtitleFont(), NSColor.secondaryLabelColor);
    _factsLabel = ARLabel(@"", ARFootnoteFont(), NSColor.tertiaryLabelColor);

    // The summary is the answer, so it gets the one filled shape on the panel.
    ARFillView *summaryBox = [[ARFillView alloc] initWithFrame: NSZeroRect];
    summaryBox.cornerRadius = 8;
    summaryBox.fillColor = [NSColor.controlAccentColor colorWithAlphaComponent: 0.12];
    summaryBox.translatesAutoresizingMaskIntoConstraints = NO;
    [summaryBox addSubview: _summaryLabel];

    NSView *content = _panel.contentView;
    for (NSView *view in @[_windowLabel, _appLabel, summaryBox, _traceLabel, _factsLabel]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        if (view != summaryBox) { [content addSubview: view]; }
    }
    [content addSubview: summaryBox];

    CGFloat width = AR_INSPECTOR_WIDTH - 2 * AR_INSPECTOR_MARGIN;
    for (NSTextField *label in @[_windowLabel, _appLabel, _traceLabel, _factsLabel]) {
        label.preferredMaxLayoutWidth = width;
    }
    _summaryLabel.preferredMaxLayoutWidth = width - 20;

    [NSLayoutConstraint activateConstraints: @[
        [_windowLabel.topAnchor constraintEqualToAnchor: content.topAnchor
            constant: AR_INSPECTOR_MARGIN],
        [_windowLabel.leadingAnchor constraintEqualToAnchor: content.leadingAnchor
            constant: AR_INSPECTOR_MARGIN],
        [_windowLabel.trailingAnchor constraintEqualToAnchor: content.trailingAnchor
            constant: -AR_INSPECTOR_MARGIN],

        [_appLabel.topAnchor constraintEqualToAnchor: _windowLabel.bottomAnchor constant: 2],
        [_appLabel.leadingAnchor constraintEqualToAnchor: _windowLabel.leadingAnchor],
        [_appLabel.trailingAnchor constraintEqualToAnchor: _windowLabel.trailingAnchor],

        [summaryBox.topAnchor constraintEqualToAnchor: _appLabel.bottomAnchor constant: 10],
        [summaryBox.leadingAnchor constraintEqualToAnchor: _windowLabel.leadingAnchor],
        [summaryBox.trailingAnchor constraintEqualToAnchor: _windowLabel.trailingAnchor],
        [_summaryLabel.topAnchor constraintEqualToAnchor: summaryBox.topAnchor constant: 7],
        [_summaryLabel.bottomAnchor constraintEqualToAnchor: summaryBox.bottomAnchor constant: -7],
        [_summaryLabel.leadingAnchor constraintEqualToAnchor: summaryBox.leadingAnchor constant: 10],
        [_summaryLabel.trailingAnchor constraintEqualToAnchor: summaryBox.trailingAnchor
            constant: -10],

        [_traceLabel.topAnchor constraintEqualToAnchor: summaryBox.bottomAnchor constant: 10],
        [_traceLabel.leadingAnchor constraintEqualToAnchor: _windowLabel.leadingAnchor],
        [_traceLabel.trailingAnchor constraintEqualToAnchor: _windowLabel.trailingAnchor],

        [_factsLabel.topAnchor constraintEqualToAnchor: _traceLabel.bottomAnchor constant: 10],
        [_factsLabel.leadingAnchor constraintEqualToAnchor: _windowLabel.leadingAnchor],
        [_factsLabel.trailingAnchor constraintEqualToAnchor: _windowLabel.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor: _factsLabel.bottomAnchor
            constant: AR_INSPECTOR_MARGIN],
    ]];
}

//------------------------------------------------ showing --------------------------------------------------

- (void)show {
    [self build];
    if (!_panel.isVisible) {
        // Bottom right of the main screen, out of the way of what is being
        // hovered, unless it has been dragged somewhere before.
        if (NSEqualPoints(_panel.frame.origin, NSZeroPoint)) {
            NSRect screen = NSScreen.mainScreen.visibleFrame;
            [_panel setFrameOrigin: NSMakePoint(
                NSMaxX(screen) - _panel.frame.size.width - 20, NSMinY(screen) + 20)];
        }
        [_panel orderFrontRegardless];
    }
}

- (void)hide { [_panel orderOut: nil]; }

- (void)toggle {
    if (self.visible) { [self hide]; } else { [self show]; }
}

//------------------------------------------------ updating -------------------------------------------------

- (void)updateWithWindow:(NSString *)window
                     app:(NSString *)app
                 summary:(NSString *)summary
                   trace:(NSArray<NSString *> *)trace
                   facts:(NSArray<NSString *> *)facts {
    if (!_panel.isVisible) { return; }

    NSString *windowText = window.length ? window : @"Nothing under the pointer";
    NSString *appText = app.length ? app : @"";
    // The rules read as a list, with the one that settled it last.
    NSMutableString *traceText = [NSMutableString string];
    for (NSString *line in trace) {
        [traceText appendFormat: traceText.length ? @"\n· %@" : @"· %@", line];
    }
    if (!traceText.length) { [traceText appendString: @"· No rule had anything to say"]; }
    NSString *factsText = [facts componentsJoinedByString: @"\n"];

    NSString *content = [@[windowText, appText, summary, traceText, factsText]
        componentsJoinedByString: @"␞"];
    if ([content isEqualToString: _lastContent]) { return; }
    _lastContent = content;

    _windowLabel.stringValue = windowText;
    _appLabel.stringValue = appText;
    _summaryLabel.stringValue = summary;
    _traceLabel.stringValue = traceText;
    _factsLabel.stringValue = factsText;
}

@end
