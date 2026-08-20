/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Shortcut: the global key combination that toggles AutoRaise.
 *
 * Stored in the settings file as words a human can type, "control-option-A",
 * and shown in the interface the way macOS writes shortcuts, ⌃⌥A.
 */

#import <Carbon/Carbon.h>

#import "Config.h"

typedef struct {
    unsigned short keyCode;
    const char *name;
    const char *symbol;   // what the interface shows, NULL means use the name
} ARKeyName;

// Only the keys worth binding. Letters and digits come from the layout below.
static const ARKeyName ARKeyNames[] = {
    {kVK_Space, "Space", "Space"},        {kVK_Return, "Return", "↩"},
    {kVK_Tab, "Tab", "⇥"},           {kVK_Escape, "Escape", "⎋"},
    {kVK_Delete, "Delete", "⌫"},     {kVK_ForwardDelete, "ForwardDelete", "⌦"},
    {kVK_LeftArrow, "Left", "←"},    {kVK_RightArrow, "Right", "→"},
    {kVK_UpArrow, "Up", "↑"},        {kVK_DownArrow, "Down", "↓"},
    {kVK_Home, "Home", "↖"},         {kVK_End, "End", "↘"},
    {kVK_PageUp, "PageUp", "⇞"},     {kVK_PageDown, "PageDown", "⇟"},
    {kVK_ANSI_Grave, "Grave", "`"},       {kVK_ANSI_Minus, "Minus", "-"},
    {kVK_ANSI_Equal, "Equal", "="},       {kVK_ANSI_Slash, "Slash", "/"},
    {kVK_ANSI_Backslash, "Backslash", "\\"},
    {kVK_ANSI_Semicolon, "Semicolon", ";"},
    {kVK_ANSI_Quote, "Quote", "'"},       {kVK_ANSI_Comma, "Comma", ","},
    {kVK_ANSI_Period, "Period", "."},     {kVK_ANSI_LeftBracket, "LeftBracket", "["},
    {kVK_ANSI_RightBracket, "RightBracket", "]"},
    {kVK_F1, "F1", NULL},   {kVK_F2, "F2", NULL},   {kVK_F3, "F3", NULL},
    {kVK_F4, "F4", NULL},   {kVK_F5, "F5", NULL},   {kVK_F6, "F6", NULL},
    {kVK_F7, "F7", NULL},   {kVK_F8, "F8", NULL},   {kVK_F9, "F9", NULL},
    {kVK_F10, "F10", NULL}, {kVK_F11, "F11", NULL}, {kVK_F12, "F12", NULL},
    {kVK_F13, "F13", NULL}, {kVK_F14, "F14", NULL}, {kVK_F15, "F15", NULL},
    {kVK_F16, "F16", NULL}, {kVK_F17, "F17", NULL}, {kVK_F18, "F18", NULL},
    {kVK_F19, "F19", NULL}, {kVK_F20, "F20", NULL},
};

// ANSI layout, so a shortcut written as "A" means the key labelled A.
static const ARKeyName ARAnsiKeys[] = {
    {kVK_ANSI_A, "A", NULL}, {kVK_ANSI_B, "B", NULL}, {kVK_ANSI_C, "C", NULL},
    {kVK_ANSI_D, "D", NULL}, {kVK_ANSI_E, "E", NULL}, {kVK_ANSI_F, "F", NULL},
    {kVK_ANSI_G, "G", NULL}, {kVK_ANSI_H, "H", NULL}, {kVK_ANSI_I, "I", NULL},
    {kVK_ANSI_J, "J", NULL}, {kVK_ANSI_K, "K", NULL}, {kVK_ANSI_L, "L", NULL},
    {kVK_ANSI_M, "M", NULL}, {kVK_ANSI_N, "N", NULL}, {kVK_ANSI_O, "O", NULL},
    {kVK_ANSI_P, "P", NULL}, {kVK_ANSI_Q, "Q", NULL}, {kVK_ANSI_R, "R", NULL},
    {kVK_ANSI_S, "S", NULL}, {kVK_ANSI_T, "T", NULL}, {kVK_ANSI_U, "U", NULL},
    {kVK_ANSI_V, "V", NULL}, {kVK_ANSI_W, "W", NULL}, {kVK_ANSI_X, "X", NULL},
    {kVK_ANSI_Y, "Y", NULL}, {kVK_ANSI_Z, "Z", NULL},
    {kVK_ANSI_0, "0", NULL}, {kVK_ANSI_1, "1", NULL}, {kVK_ANSI_2, "2", NULL},
    {kVK_ANSI_3, "3", NULL}, {kVK_ANSI_4, "4", NULL}, {kVK_ANSI_5, "5", NULL},
    {kVK_ANSI_6, "6", NULL}, {kVK_ANSI_7, "7", NULL}, {kVK_ANSI_8, "8", NULL},
    {kVK_ANSI_9, "9", NULL},
};

static BOOL ARLookupKeyName(unsigned short keyCode, const ARKeyName **out) {
    for (size_t i = 0; i < sizeof(ARKeyNames) / sizeof(ARKeyNames[0]); i++) {
        if (ARKeyNames[i].keyCode == keyCode) { *out = &ARKeyNames[i]; return YES; }
    }
    for (size_t i = 0; i < sizeof(ARAnsiKeys) / sizeof(ARAnsiKeys[0]); i++) {
        if (ARAnsiKeys[i].keyCode == keyCode) { *out = &ARAnsiKeys[i]; return YES; }
    }
    return NO;
}

static BOOL ARLookupKeyCode(NSString *name, unsigned short *out) {
    for (size_t i = 0; i < sizeof(ARKeyNames) / sizeof(ARKeyNames[0]); i++) {
        if ([name caseInsensitiveCompare: @(ARKeyNames[i].name)] == NSOrderedSame) {
            *out = ARKeyNames[i].keyCode;
            return YES;
        }
    }
    for (size_t i = 0; i < sizeof(ARAnsiKeys) / sizeof(ARAnsiKeys[0]); i++) {
        if ([name caseInsensitiveCompare: @(ARAnsiKeys[i].name)] == NSOrderedSame) {
            *out = ARAnsiKeys[i].keyCode;
            return YES;
        }
    }
    return NO;
}

ARShortcut ARShortcutParse(NSString *text) {
    ARShortcut shortcut = {NO, 0, 0};
    if (!text.length) { return shortcut; }

    NSArray<NSString *> *parts = [text componentsSeparatedByString: @"-"];
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *part = [parts[i] stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceCharacterSet]];
        if (!part.length) { continue; }

        if ([part caseInsensitiveCompare: @"control"] == NSOrderedSame ||
            [part caseInsensitiveCompare: @"ctrl"] == NSOrderedSame) {
            shortcut.modifiers |= kCGEventFlagMaskControl;
        } else if ([part caseInsensitiveCompare: @"option"] == NSOrderedSame ||
                   [part caseInsensitiveCompare: @"alt"] == NSOrderedSame) {
            shortcut.modifiers |= kCGEventFlagMaskAlternate;
        } else if ([part caseInsensitiveCompare: @"command"] == NSOrderedSame ||
                   [part caseInsensitiveCompare: @"cmd"] == NSOrderedSame) {
            shortcut.modifiers |= kCGEventFlagMaskCommand;
        } else if ([part caseInsensitiveCompare: @"shift"] == NSOrderedSame) {
            shortcut.modifiers |= kCGEventFlagMaskShift;
        } else if (ARLookupKeyCode(part, &shortcut.keyCode)) {
            shortcut.valid = YES;
        } else {
            return (ARShortcut) {NO, 0, 0};
        }
    }

    // A bare key would fire while typing, so at least one modifier is required.
    if (!shortcut.modifiers) { shortcut.valid = NO; }
    return shortcut;
}

NSString *ARShortcutDescribe(ARShortcut shortcut) {
    if (!shortcut.valid) { return nil; }
    const ARKeyName *key = NULL;
    if (!ARLookupKeyName(shortcut.keyCode, &key)) { return nil; }

    NSMutableArray *parts = [NSMutableArray array];
    if (shortcut.modifiers & kCGEventFlagMaskControl) { [parts addObject: @"control"]; }
    if (shortcut.modifiers & kCGEventFlagMaskAlternate) { [parts addObject: @"option"]; }
    if (shortcut.modifiers & kCGEventFlagMaskShift) { [parts addObject: @"shift"]; }
    if (shortcut.modifiers & kCGEventFlagMaskCommand) { [parts addObject: @"command"]; }
    [parts addObject: @(key->name)];
    return [parts componentsJoinedByString: @"-"];
}

NSString *ARShortcutDisplay(ARShortcut shortcut) {
    if (!shortcut.valid) { return @"None"; }
    const ARKeyName *key = NULL;
    if (!ARLookupKeyName(shortcut.keyCode, &key)) { return @"None"; }

    NSMutableString *display = [NSMutableString string];
    // The order macOS uses on menu items.
    if (shortcut.modifiers & kCGEventFlagMaskControl) { [display appendString: @"⌃"]; }
    if (shortcut.modifiers & kCGEventFlagMaskAlternate) { [display appendString: @"⌥"]; }
    if (shortcut.modifiers & kCGEventFlagMaskShift) { [display appendString: @"⇧"]; }
    if (shortcut.modifiers & kCGEventFlagMaskCommand) { [display appendString: @"⌘"]; }
    [display appendString: @(key->symbol ?: key->name)];
    return display;
}
