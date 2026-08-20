/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 */

#import "MenuBar.h"
#import "Config.h"

#import <ServiceManagement/ServiceManagement.h>

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

- (BOOL)loginItemAvailable {
    if (@available(macOS 13.0, *)) {
        // Registering only means something for a real bundle.
        return NSBundle.mainBundle.bundleIdentifier != nil;
    }
    return NO;
}

- (BOOL)loginItemEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    id<ARMenuBarDelegate> delegate = self.delegate;

    NSMenuItem *status = [[NSMenuItem alloc] initWithTitle: delegate.statusSummary
        action: nil keyEquivalent: @""];
    status.enabled = NO;
    [menu addItem: status];

    if (!delegate.accessibilityGranted) {
        [menu addItem: [NSMenuItem separatorItem]];
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

    if (self.loginItemAvailable) {
        NSMenuItem *login = [[NSMenuItem alloc] initWithTitle: @"Open at Login"
            action: @selector(toggleLoginItem:) keyEquivalent: @""];
        login.target = self;
        login.state = self.loginItemEnabled ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem: login];
    }

    [menu addItem: [NSMenuItem separatorItem]];

    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle: @"Edit Configuration…"
        action: @selector(editConfiguration:) keyEquivalent: @""];
    edit.target = self;
    [menu addItem: edit];

    NSMenuItem *reload = [[NSMenuItem alloc] initWithTitle: @"Reload Configuration"
        action: @selector(reloadConfiguration:) keyEquivalent: @"r"];
    reload.target = self;
    [menu addItem: reload];

    NSMenuItem *verbose = [[NSMenuItem alloc] initWithTitle: @"Verbose Logging"
        action: @selector(toggleVerbose:) keyEquivalent: @""];
    verbose.target = self;
    verbose.state = delegate.verboseLogging ? NSControlStateValueOn : NSControlStateValueOff;
    verbose.toolTip = @"Log every decision to the system log: log stream --process AutoRaise";
    [menu addItem: verbose];

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

- (void)toggleVerbose:(id)sender {
    [self.delegate setVerboseLogging: !self.delegate.verboseLogging];
}

- (void)toggleLoginItem:(id)sender {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = self.loginItemEnabled
            ? [SMAppService.mainAppService unregisterAndReturnError: &error]
            : [SMAppService.mainAppService registerAndReturnError: &error];
        if (!ok) {
            NSLog(@"Could not change the login item: %@", error.localizedDescription);
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"Could not change the login item";
            alert.informativeText = error.localizedDescription ?:
                @"Move AutoRaise.app to /Applications and try again.";
            [alert runModal];
        }
    }
}

- (void)editConfiguration:(id)sender {
    NSString *path = self.delegate.configurationPath;
    if (path) { [[NSWorkspace sharedWorkspace] openURL: [NSURL fileURLWithPath: path]]; }
}

- (void)reloadConfiguration:(id)sender {
    [self.delegate reloadConfiguration];
    [self refresh];
}

- (void)openAccessibilitySettings:(id)sender {
    NSURL *url = [NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
    [[NSWorkspace sharedWorkspace] openURL: url];
}

- (void)quit:(id)sender {
    [NSApp terminate: nil];
}

@end
