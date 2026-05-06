//
//  GhosttyFrameLoader.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/12/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads pre-rendered ASCII frames from a bundle's `frame_NNN.txt`
/// resources and returns them as NSAttributedStrings, with `<span class="b">…</span>`
/// blocks rendered blue and the surrounding text white.
@interface GhosttyFrameLoader : NSObject

/// Loads all matching frames from `bundle`, sorted lexicographically.
/// Filters resources by basename (`frame_\d+\.txt`) so unrelated `.txt`
/// files at the bundle root cannot leak into the animation.
///
/// @param bundle The bundle in which to look for frame resources.
/// @return An array of NSAttributedString frames; empty if none found.
- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle;

/// Process-singleton accessor backed by `dispatch_once`. The first caller
/// pays the load cost; every subsequent caller (multi-display, System
/// Settings preview pane, view re-instantiation) returns instantly with
/// the same immutable array.
///
/// The frames are bound to the first bundle passed in. Subsequent calls
/// with a different bundle return the original cache — for screensaver
/// use this is fine because `+[NSBundle bundleForClass:]` is stable.
+ (NSArray<NSAttributedString *> *)sharedFramesForBundle:(NSBundle *)bundle;

@end

NS_ASSUME_NONNULL_END
