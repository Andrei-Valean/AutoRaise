/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Distributed under the GNU General Public License v2 or later, see LICENSE.md
 *
 * Quirks: the app-specific knowledge that used to be hardcoded in the binary.
 *
 * Built-in defaults cover the apps reported so far. A user file at
 * ~/.config/AutoRaise/quirks.json (or ~/.AutoRaise.quirks.json) extends them,
 * so a new misbehaving app is a data change, not a release.
 */

#pragma once

#import "Policy.h"

NS_ASSUME_NONNULL_BEGIN

ARQuirks *ARQuirksDefaults(void);

// Returns the path that was loaded, or nil when no user file exists. Entries in
// the file are appended to the built-ins unless it sets "replaceDefaults": true.
// Parse failures leave the defaults untouched and report through error.
NSString *_Nullable ARQuirksUserFilePath(void);
ARQuirks *ARQuirksLoad(NSString *_Nullable path, NSError *_Nullable *_Nullable error);

// Merge used by ARQuirksLoad, exposed for tests.
ARQuirks *ARQuirksApplyOverrides(ARQuirks *base, NSDictionary *overrides, NSError *_Nullable *_Nullable error);

// The default quirks as JSON, written out by "AutoRaise -dumpQuirks" so users
// have a starting point that matches the version they run.
NSString *ARQuirksJSON(ARQuirks *quirks);

NS_ASSUME_NONNULL_END
