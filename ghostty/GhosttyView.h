//
//  GhosttyView.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/11/25.
//

#import <ScreenSaver/ScreenSaver.h>

@class GhosttyColorScheme;

NS_ASSUME_NONNULL_BEGIN

/// macOS screensaver view that cycles a sequence of pre-rendered ASCII
/// art frames at 30 FPS. On macOS 14 and later a display link paces the
/// frames to the display's refresh; before that ScreenSaverView's timer
/// does. Frames are loaded per color scheme by
/// GhosttyFrameLoader (shared across all NSScreen instances and the
/// System Settings preview pane) and rendered via Core Text into a
/// layer-backed view. The scheme is read from ScreenSaverDefaults once, at
/// init, and changed at runtime only by the Options sheet.
///
/// The class name is referenced as a string in
/// INFOPLIST_KEY_NSPrincipalClass; any rename must update the project's
/// Info.plist generation in lockstep.
@interface GhosttyView : ScreenSaverView

/// Swaps the frames and the layer background for `scheme` and redraws.
/// Idempotent. Called from init, from the scheme-change notification the
/// Options sheet posts, and by the test harness.
- (void)applyScheme:(GhosttyColorScheme *)scheme;

@end

NS_ASSUME_NONNULL_END
