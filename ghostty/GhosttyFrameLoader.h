//
//  GhosttyFrameLoader.h
//  ghostty
//
//  Created by Wayne Wen on 1/12/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 A helper class for scanning .txt resources within a given bundle
 and converting them into frames (NSAttributedStrings), with special
 handling for <span class="b">…</span> tags to render text in blue.
 */
@interface GhosttyFrameLoader : NSObject

/**
 Loads all ASCII frames (as attributed strings) from the given bundle,
 parsing any `<span class="b">... </span>` sections as blue text.
 
 @param bundle The bundle in which to search for `.txt` resources
 @return An array of NSAttributedString frames, or an empty array if none are found.
 */
- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle;

/**
 Converts an array of NSAttributedString frames into NSImage objects by
 rendering each string offscreen. Useful for performance-critical code
 (e.g. screensaver animation), as drawing a pre-rendered image is faster
 than drawing text each frame.

 @param frames An array of NSAttributedString objects
 @return An array of NSImage objects, each containing the rendered text
 */
- (NSArray<NSImage *> *)buildFrameImagesFromAttributedStrings:(NSArray<NSAttributedString *> *)frames;

@end

NS_ASSUME_NONNULL_END
