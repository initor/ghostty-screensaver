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

@end

NS_ASSUME_NONNULL_END
