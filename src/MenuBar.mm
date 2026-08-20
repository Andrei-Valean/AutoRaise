/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "MenuBar.h"

@interface ARMenuBar () <NSMenuDelegate>
@property (nonatomic, weak) id<ARMenuBarDelegate> delegate;
@property (nonatomic, strong) NSStatusItem *statusItem;
@end

@implementation ARMenuBar

// Two window cards, the front one lifted: the same idea as the app icon, drawn
// as a template so the menu bar tints it for light, dark and highlighted states.
+ (NSImage *)statusImage {
    NSSize size = NSMakeSize(18, 18);
    NSImage *image = [NSImage imageWithSize: size flipped: NO drawingHandler: ^BOOL(NSRect rect) {
        [[NSColor blackColor] set];

        // Back window: outline, sitting behind and above.
        NSBezierPath *back = [NSBezierPath bezierPathWithRoundedRect: NSMakeRect(2.75, 6.25, 9.5, 8)
                                                            xRadius: 2 yRadius: 2];
        back.lineWidth = 1.3;
        [back stroke];

        // Clear a gap where the front window overlaps, so both cards stay
        // readable at menu bar size, then draw the front one solid.
        NSBezierPath *gap = [NSBezierPath bezierPathWithRoundedRect: NSMakeRect(5.4, 2.4, 10.7, 9.2)
                                                           xRadius: 2.6 yRadius: 2.6];
        [NSGraphicsContext currentContext].compositingOperation = NSCompositingOperationDestinationOut;
        [gap fill];
        [NSGraphicsContext currentContext].compositingOperation = NSCompositingOperationSourceOver;

        NSBezierPath *front = [NSBezierPath bezierPathWithRoundedRect: NSMakeRect(6.2, 3.2, 9.1, 7.6)
                                                             xRadius: 2 yRadius: 2];
        [front fill];
        return YES;
    }];
    [image setTemplate: YES];
    return image;
}

- (instancetype)initWithDelegate:(id<ARMenuBarDelegate>)delegate {
    if ((self = [super init])) {
        _delegate = delegate;
        _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength: NSSquareStatusItemLength];
        _statusItem.button.image = [ARMenuBar statusImage];
        _statusItem.button.toolTip = @"AutoRaise";
        _statusItem.behavior = NSStatusItemBehaviorTerminationOnRemoval;
        NSMenu *menu = [[NSMenu alloc] init];
        menu.delegate = self;
        _statusItem.menu = menu;
        [self refresh];
    }
    return self;
}

- (void)remove {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem: self.statusItem];
        self.statusItem = nil;
    }
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    id<ARMenuBarDelegate> delegate = self.delegate;

    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle: delegate.statusSummary
        action: nil keyEquivalent: @""];
    status.enabled = NO;
    [menu addItem: status];

    if (!delegate.accessibilityGranted) {
        NSMenuItem *grant = [[NSMenuItem alloc] initWithTitle: @"Grant Accessibility Access…"
            action: @selector(openAccessibilitySettings:) keyEquivalent: @""];
        grant.target = self;
        [menu addItem: grant];
    }

    [menu addItem: [NSMenuItem separatorItem]];

    NSMenuItem *enabled = [[NSMenuItem alloc] initWithTitle: @"Enabled"
        action: @selector(toggleEnabled:) keyEquivalent: @""];
    enabled.target = self;
    enabled.state = delegate.autoRaiseEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem: enabled];

    if (delegate.loginItemAvailable) {
        NSMenuItem *login = [[NSMenuItem alloc] initWithTitle: @"Open at Login"
            action: @selector(toggleLoginItem:) keyEquivalent: @""];
        login.target = self;
        login.state = delegate.loginItemEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem: login];
    }

    [menu addItem: [NSMenuItem separatorItem]];

    NSMenuItem *settings = [[NSMenuItem alloc] initWithTitle: @"Settings…"
        action: @selector(openSettings:) keyEquivalent: @","];
    settings.target = self;
    [menu addItem: settings];

    [menu addItem: [NSMenuItem separatorItem]];

    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle: @"Quit AutoRaise"
        action: @selector(quit:) keyEquivalent: @"q"];
    quit.target = self;
    [menu addItem: quit];
}

- (void)refresh {
    id<ARMenuBarDelegate> delegate = self.delegate;
    BOOL dimmed = !delegate.autoRaiseEnabled || !delegate.accessibilityGranted;
    self.statusItem.button.appearsDisabled = dimmed;
    self.statusItem.button.toolTip = delegate.statusSummary;
}

- (void)toggleEnabled:(id)sender {
    [self.delegate setAutoRaiseEnabled: !self.delegate.autoRaiseEnabled];
    [self refresh];
}

- (void)toggleLoginItem:(id)sender {
    [self.delegate setLoginItemEnabled: !self.delegate.loginItemEnabled];
}

- (void)openSettings:(id)sender {
    [self.delegate openSettings];
}

- (void)openAccessibilitySettings:(id)sender {
    [self.delegate requestAccessibility];
}

- (void)quit:(id)sender {
    [NSApp terminate: nil];
}

@end
