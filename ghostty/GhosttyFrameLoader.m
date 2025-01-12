//
//  GhosttyFrameLoader.m
//  ghostty
//
//  Created by Wayne Wen on 1/12/25.
//

#import "GhosttyFrameLoader.h"
#import <AppKit/AppKit.h> // Needed for NSColor, NSFont, etc.

@interface GhosttyFrameLoader ()

/**
 Parses `<span class="b">... </span>` blocks as blue text,
 while everything else is white.
 
 @param raw A raw string that may contain span tags
 @return A fully attributed string with color highlights for the span.
 */
- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw;

@end

@implementation GhosttyFrameLoader

#pragma mark - Public API

- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle
{
    NSLog(@"[GhosttyFrameLoader] Scanning .txt resources in %@", bundle.bundlePath);

    // 1) Find all .txt files in the bundle
    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];
    // 2) Sort them so they load in a predictable order (optional)
    paths = [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    // 3) Attempt to parse them into attributed strings
    NSMutableArray<NSAttributedString *> *loadedFrames = [NSMutableArray array];
    for (NSString *path in paths) {
        NSError *error = nil;
        NSString *rawContent = [NSString stringWithContentsOfFile:path
                                                         encoding:NSUTF8StringEncoding
                                                            error:&error];
        if (!rawContent || error) {
            NSLog(@"[GhosttyFrameLoader] Could not read %@ (error=%@)", path, error);
            continue; // Skip files that fail to load
        }

        // 4) Convert raw text to attributed text
        NSAttributedString *frameAS = [self attributedFrameFromRawHTML:rawContent];
        [loadedFrames addObject:frameAS];

        NSLog(@"[GhosttyFrameLoader] Loaded frame from %@", path);
    }

    NSLog(@"[GhosttyFrameLoader] Total frames loaded: %lu", (unsigned long)loadedFrames.count);
    return [loadedFrames copy];
}

#pragma mark - Private Helpers

- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw
{
    // Define your colors
    NSColor *blueColor  = [NSColor colorWithSRGBRed:0.0
                                             green:0.0
                                              blue:(230.0 / 255.0)
                                             alpha:1.0];
    NSColor *whiteColor = [NSColor colorWithSRGBRed:(215.0 / 255.0)
                                             green:(215.0 / 255.0)
                                              blue:(215.0 / 255.0)
                                             alpha:1.0];

    // Monospaced font for ASCII art
    NSFont *monospacedFont = [NSFont fontWithName:@"Menlo" size:16.0];

    // Attributes for white vs. blue text
    NSDictionary *attrsWhite = @{
        NSFontAttributeName: monospacedFont,
        NSForegroundColorAttributeName: whiteColor
    };
    NSDictionary *attrsBlue = @{
        NSFontAttributeName: monospacedFont,
        NSForegroundColorAttributeName: blueColor
    };

    // Regex that finds `<span class="b">…</span>` blocks
    NSString *pattern = @"<span class=\"b\">(.*?)</span>";
    NSRegularExpressionOptions options = NSRegularExpressionDotMatchesLineSeparators;
    NSError *regexError = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:options
                                                    error:&regexError];
    if (!regex) {
        NSLog(@"[GhosttyFrameLoader] Regex creation error: %@", regexError);
        // Fallback: entire text in white
        return [[NSAttributedString alloc] initWithString:raw attributes:attrsWhite];
    }

    // Build the parsed output
    NSMutableAttributedString *parsed = [[NSMutableAttributedString alloc] init];
    NSUInteger lastLoc = 0;
    NSArray<NSTextCheckingResult *> *matches =
        [regex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];

    for (NSTextCheckingResult *match in matches) {
        // The entire `<span...>...</span>` block
        NSRange fullMatchRange = [match rangeAtIndex:0];
        // The text inside the span
        NSRange innerRange     = [match rangeAtIndex:1];

        // Append outside text as white
        if (fullMatchRange.location > lastLoc) {
            NSRange outsideRange = NSMakeRange(lastLoc, fullMatchRange.location - lastLoc);
            NSString *outsideText = [raw substringWithRange:outsideRange];
            NSAttributedString *outsideAS =
                [[NSAttributedString alloc] initWithString:outsideText attributes:attrsWhite];
            [parsed appendAttributedString:outsideAS];
        }

        // Append the span text as blue
        NSString *blueText = [raw substringWithRange:innerRange];
        NSAttributedString *blueAS =
            [[NSAttributedString alloc] initWithString:blueText attributes:attrsBlue];
        [parsed appendAttributedString:blueAS];

        // Move the pointer
        lastLoc = fullMatchRange.location + fullMatchRange.length;
    }

    // Append any trailing text (also white)
    if (lastLoc < raw.length) {
        NSRange trailingRange = NSMakeRange(lastLoc, raw.length - lastLoc);
        NSString *trailingText = [raw substringWithRange:trailingRange];
        NSAttributedString *trailingAS =
            [[NSAttributedString alloc] initWithString:trailingText attributes:attrsWhite];
        [parsed appendAttributedString:trailingAS];
    }

    return [parsed copy];
}

@end
