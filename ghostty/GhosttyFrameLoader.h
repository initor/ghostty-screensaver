//
//  GhosttyFrameLoader.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/12/25.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@class GhosttyColorScheme;

NS_ASSUME_NONNULL_BEGIN

/// Loads pre-rendered ASCII frames from a bundle's `frame_NNN.txt`
/// resources and returns them as NSAttributedStrings colored for one
/// GhosttyColorScheme: the text inside `<span class="b">…</span>` gets the
/// scheme's accent color, everything else its body color.
///
/// Main thread only. Every caller (view init, the Options sheet, the test
/// harness) is on the main thread by AppKit contract, so the class-level
/// cache below is plain statics rather than a lock.
@interface GhosttyFrameLoader : NSObject

/// Loads all matching frames from `bundle`, sorted lexicographically, and
/// colors them for `scheme`. Filters resources by basename
/// (`frame_\d+\.txt`) so unrelated `.txt` files at the bundle root cannot
/// leak into the animation. Uncached; see +framesForScheme:bundle:.
///
/// @param bundle The bundle in which to look for frame resources.
/// @param scheme The scheme whose body and accent colors to bake in.
/// @return An array of NSAttributedString frames; empty if none found.
- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle
                                                 scheme:(GhosttyColorScheme *)scheme;

/// Frames for `scheme`, loaded on a miss and kept until a different scheme
/// is requested. A second view with the same scheme (multi-display, the
/// System Settings preview pane) returns the same array. A different scheme
/// replaces the cached set; views keep a strong reference to their own
/// array, so replacement never pulls frames out from under a running view.
/// An empty load is not cached, so a transient failure can retry.
+ (NSArray<NSAttributedString *> *)framesForScheme:(GhosttyColorScheme *)scheme
                                            bundle:(NSBundle *)bundle;

/// The canvas every frame lays out in: 100 columns by 41 rows at the shared
/// font. Depends on font and corpus only, so it holds for every scheme.
/// Zero until the first non-empty load.
+ (CGSize)canvasSize;

/// Midpoint of the union of visible ink over the whole loop, in canvas
/// coordinates. One anchor for the whole animation preserves its authored
/// motion instead of recentering per frame. Computed once per process.
+ (CGFloat)inkMidpoint;

@end

NS_ASSUME_NONNULL_END
