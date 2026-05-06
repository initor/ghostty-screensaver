//
//  ghosttyView.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/11/25.
//

#import <ScreenSaver/ScreenSaver.h>

NS_ASSUME_NONNULL_BEGIN

/// macOS screensaver view that cycles a sequence of pre-rendered ASCII
/// art frames at 30 FPS. Frames are loaded once per process by
/// GhosttyFrameLoader (shared across all NSScreen instances and the
/// System Settings preview pane via dispatch_once) and rendered via
/// Core Text into a layer-backed view.
///
/// The class name is referenced as a string in
/// INFOPLIST_KEY_NSPrincipalClass; any rename must update the project's
/// Info.plist generation in lockstep.
@interface ghosttyView : ScreenSaverView
@end

NS_ASSUME_NONNULL_END
