//
//  GhosttyFrameLoader.m
//  ghostty
//
//  Created by Wayne Wen on 1/12/25.
//

#import "GhosttyFrameLoader.h"
#import <AppKit/AppKit.h> // Needed for NSColor, NSFont, etc.

// file-level statics (visible only in this .m file)
static NSColor *sBlueColor;
static NSColor *sWhiteColor;
static NSFont  *sMonospacedFont;

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

#pragma mark - One-Time Initialization

+ (void)initialize
{
    // +initialize is called automatically by the runtime the first time
    // this class or any subclass is referenced.
    // Make sure it only initializes once, and only for this class.
    if (self == [GhosttyFrameLoader class]) {
        sBlueColor = [NSColor colorWithSRGBRed:0.0
                                        green:0.0
                                         blue:(230.0 / 255.0)
                                        alpha:1.0];

        sWhiteColor = [NSColor colorWithSRGBRed:(215.0 / 255.0)
                                         green:(215.0 / 255.0)
                                          blue:(215.0 / 255.0)
                                         alpha:1.0];

        sMonospacedFont = [NSFont fontWithName:@"Menlo" size:16.0];
    }
}

#pragma mark - Public API

- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle
{
    NSLog(@"[GhosttyFrameLoader] Scanning .txt resources in %@", bundle.bundlePath);

    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];
    paths = [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    NSMutableArray<NSAttributedString *> *loadedFrames = [NSMutableArray array];
    for (NSString *path in paths) {
        NSError *error = nil;
        NSString *rawContent = [NSString stringWithContentsOfFile:path
                                                         encoding:NSUTF8StringEncoding
                                                            error:&error];
        if (!rawContent || error) {
            NSLog(@"[GhosttyFrameLoader] Could not read %@ (error=%@)", path, error);
            continue; // fail-open
        }

        // decorate loaded .txt file into NSAttributedString obj
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
    NSDictionary *attrsWhite = @{
        NSFontAttributeName: sMonospacedFont,
        NSForegroundColorAttributeName: sWhiteColor
    };
    NSDictionary *attrsBlue = @{
        NSFontAttributeName: sMonospacedFont,
        NSForegroundColorAttributeName: sBlueColor
    };

    // regex that finds `<span class="b">…</span>` blocks
    NSString *pattern = @"<span class=\"b\">(.*?)</span>";
    NSRegularExpressionOptions options = NSRegularExpressionDotMatchesLineSeparators;
    NSError *regexError = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:options
                                                    error:&regexError];
    if (!regex) {
        NSLog(@"[GhosttyFrameLoader] Regex creation error: %@", regexError);
        // fail-open
        return [[NSAttributedString alloc] initWithString:raw attributes:attrsWhite];
    }

    NSMutableAttributedString *parsed = [[NSMutableAttributedString alloc] init];
    NSUInteger lastLoc = 0;
    NSArray<NSTextCheckingResult *> *matches =
        [regex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];

    for (NSTextCheckingResult *match in matches) {
        NSRange fullMatchRange = [match rangeAtIndex:0];
        NSRange innerRange     = [match rangeAtIndex:1];

        // appen outside text as white
        if (fullMatchRange.location > lastLoc) {
            NSRange outsideRange = NSMakeRange(lastLoc, fullMatchRange.location - lastLoc);
            NSString *outsideText = [raw substringWithRange:outsideRange];
            NSAttributedString *outsideAS =
                [[NSAttributedString alloc] initWithString:outsideText attributes:attrsWhite];
            [parsed appendAttributedString:outsideAS];
        }

        // append the span text as blue
        NSString *blueText = [raw substringWithRange:innerRange];
        NSAttributedString *blueAS =
            [[NSAttributedString alloc] initWithString:blueText attributes:attrsBlue];
        [parsed appendAttributedString:blueAS];

        lastLoc = fullMatchRange.location + fullMatchRange.length;
    }

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
