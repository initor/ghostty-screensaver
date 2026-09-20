//
//  GhosttyFrameLoader.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/12/25.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads pre-rendered ASCII frames from a bundle's `frame_NNN.txt`
/// resources and returns them as NSAttributedStrings, with `<span class="b">…</span>`
/// blocks rendered blue and the surrounding text white.
///
/// Main thread only. Every caller (view init, the test harness) is on the
/// main thread by AppKit contract, so the class-level cache below is plain
/// statics rather than a lock.
@interface GhosttyFrameLoader : NSObject

/// Loads all matching frames from `bundle`, sorted lexicographically.
/// Filters resources by basename (`frame_\d+\.txt`) so unrelated `.txt`
/// files at the bundle root cannot leak into the animation. Uncached; see
/// +sharedFramesForBundle:.
///
/// @param bundle The bundle in which to look for frame resources.
/// @return An array of NSAttributedString frames; empty if none found.
- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle;

/// Process-singleton accessor. The first caller pays the load cost; every
/// subsequent caller (multi-display, System Settings preview pane, view
/// re-instantiation) returns the same immutable array. An empty load is
/// not cached, so a transient failure on the first view can retry.
///
/// The frames are bound to the first bundle passed in. Subsequent calls
/// with a different bundle return the original cache. For screensaver use
/// this is fine because `+[NSBundle bundleForClass:]` is stable.
+ (NSArray<NSAttributedString *> *)sharedFramesForBundle:(NSBundle *)bundle;

/// The canvas every frame lays out in: 100 columns by 41 rows at the shared
/// font. Depends on font and corpus only. Zero until the first non-empty load.
+ (CGSize)canvasSize;

/// Midpoint of the union of visible ink over the whole loop, in canvas
/// coordinates. One anchor for the whole animation preserves its authored
/// motion instead of recentering per frame. Computed once per process.
+ (CGFloat)inkMidpoint;

@end

NS_ASSUME_NONNULL_END
