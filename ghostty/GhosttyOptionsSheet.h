//
//  GhosttyOptionsSheet.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 9/19/26.
//

#import <AppKit/AppKit.h>

@class GhosttyColorScheme;

NS_ASSUME_NONNULL_BEGIN

/// The Options sheet System Settings shows for this saver: a popup with the
/// built-in color schemes, Cancel, and OK. Built in code, no XIB, so the
/// project needs no resource phase and the Command Line Tools build works.
///
/// The sheet talks to views only through
/// GhosttyColorSchemeDidChangeNotification. Changing the popup applies the
/// scheme to every view in the process at once (the preview updates live).
/// OK stores the choice. Cancel reapplies the scheme the sheet opened with.
@interface GhosttyOptionsSheet : NSObject

/// The window the host runs as a sheet. Reused across requests, so it is
/// created with releasedWhenClosed = NO.
@property (nonatomic, readonly, strong) NSWindow *window;

/// Selects `scheme` in the popup and remembers it for Cancel. Called by the
/// view on every configureSheet request.
- (void)prepareWithScheme:(GhosttyColorScheme *)scheme;

@end

NS_ASSUME_NONNULL_END
