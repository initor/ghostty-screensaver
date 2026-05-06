//
//  GhosttyFrameLoader.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/12/25.
//

#import "GhosttyFrameLoader.h"
#import <AppKit/AppKit.h>
#import <os/log.h>

// File-level statics, populated once in +initialize. The hot path
// (attributedFrameFromRawHTML:) reads them branch-free, and every
// NSAttributedString allocated in this file shares the same attribute
// dictionary references — across 235 frames, this saves the original
// 470 dict allocations + 235 regex compiles in a cold init.
static NSColor *sBlueColor;
static NSColor *sWhiteColor;
static NSFont  *sMonospacedFont;
static NSDictionary<NSAttributedStringKey, id> *sAttrsWhite;
static NSDictionary<NSAttributedStringKey, id> *sAttrsBlue;
static NSRegularExpression *sSpanRegex;
static NSRegularExpression *sFilenameRegex;
static os_log_t sLog;

@interface GhosttyFrameLoader ()
- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw;
@end

@implementation GhosttyFrameLoader

#pragma mark - One-Time Initialization

+ (void)initialize
{
    if (self != [GhosttyFrameLoader class]) {
        return;
    }

    sBlueColor = [NSColor colorWithSRGBRed:0.0
                                     green:0.0
                                      blue:(230.0 / 255.0)
                                     alpha:1.0];

    sWhiteColor = [NSColor colorWithSRGBRed:(215.0 / 255.0)
                                      green:(215.0 / 255.0)
                                       blue:(215.0 / 255.0)
                                      alpha:1.0];

    // Defensive font fallback. -fontWithName:size: can return nil (Font
    // Book disable, MDM lockdown, future macOS removal). With nil, the
    // attribute-dict literal below would crash via -insertObject:nil.
    // +monospacedSystemFontOfSize:weight: (10.15+) is never-nil and honors
    // the user's preferred monospace style.
    sMonospacedFont = [NSFont fontWithName:@"Menlo" size:16.0]
                   ?: [NSFont monospacedSystemFontOfSize:16.0 weight:NSFontWeightRegular]
                   ?: [NSFont userFixedPitchFontOfSize:16.0]
                   ?: [NSFont systemFontOfSize:16.0];
    NSAssert(sMonospacedFont != nil, @"No usable monospaced font available");

    sAttrsWhite = @{
        NSFontAttributeName: sMonospacedFont,
        NSForegroundColorAttributeName: sWhiteColor
    };
    sAttrsBlue = @{
        NSFontAttributeName: sMonospacedFont,
        NSForegroundColorAttributeName: sBlueColor
    };

    // NSRegularExpressionDotMatchesLineSeparators lets `.*?` cross line
    // boundaries, which the upstream frame generator occasionally produces.
    NSError *spanRegexError = nil;
    sSpanRegex = [NSRegularExpression regularExpressionWithPattern:@"<span class=\"b\">(.*?)</span>"
                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                             error:&spanRegexError];
    NSAssert(sSpanRegex != nil, @"Span regex must compile: %@", spanRegexError);

    // Anchored basename validator. Defends against any future LICENSE.txt /
    // Credits.txt at the bundle root being silently rendered as a frame.
    NSError *filenameRegexError = nil;
    sFilenameRegex = [NSRegularExpression regularExpressionWithPattern:@"^frame_[0-9]+\\.txt$"
                                                                options:0
                                                                  error:&filenameRegexError];
    NSAssert(sFilenameRegex != nil, @"Filename regex must compile: %@", filenameRegexError);

    sLog = os_log_create("com.ghostty.screensaver", "FrameLoader");
}

#pragma mark - Public API

- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle
{
    NSParameterAssert(bundle != nil);

    NSDate *startDate = [NSDate date];
    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];

    // Frame filenames are zero-padded ("frame_001.txt" … "frame_235.txt")
    // so plain compare: produces correct lexicographic order, locale-
    // independently and ~2× faster than localizedStandardCompare:.
    paths = [paths sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<NSAttributedString *> *loadedFrames = [NSMutableArray array];
    NSUInteger skippedNonFrame = 0;
    NSUInteger skippedReadError = 0;

    for (NSString *path in paths) {
        @autoreleasepool {
            NSString *basename = [path lastPathComponent];
            NSUInteger matches = [sFilenameRegex numberOfMatchesInString:basename
                                                                 options:0
                                                                   range:NSMakeRange(0, basename.length)];
            if (matches == 0) {
                skippedNonFrame++;
                continue;
            }

            NSError *readError = nil;
            NSString *rawContent = [NSString stringWithContentsOfFile:path
                                                             encoding:NSUTF8StringEncoding
                                                                error:&readError];
            // Fail-open: a corrupt single frame should not blank the
            // whole screensaver. Log and continue.
            if (!rawContent) {
                os_log_error(sLog, "Failed to read frame %{public}@ (%{public}@)",
                             basename,
                             readError.localizedDescription ?: @"unknown");
                skippedReadError++;
                continue;
            }

            NSAttributedString *frame = [self attributedFrameFromRawHTML:rawContent];
            [loadedFrames addObject:frame];
        }
    }

    NSTimeInterval elapsedMs = [[NSDate date] timeIntervalSinceDate:startDate] * 1000.0;
    os_log_info(sLog,
                "Loaded %{public}lu frames in %.1f ms (skipped: %{public}lu non-frame, %{public}lu read errors)",
                (unsigned long)loadedFrames.count,
                elapsedMs,
                (unsigned long)skippedNonFrame,
                (unsigned long)skippedReadError);

    return [loadedFrames copy];
}

#pragma mark - Private Helpers

- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw
{
    NSMutableAttributedString *parsed = [[NSMutableAttributedString alloc] init];
    NSUInteger lastLoc = 0;
    NSArray<NSTextCheckingResult *> *matches =
        [sSpanRegex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];

    for (NSTextCheckingResult *match in matches) {
        NSRange fullMatchRange = [match rangeAtIndex:0];
        NSRange innerRange     = [match rangeAtIndex:1];

        // Append outside text (between the previous match and this one) as white.
        if (fullMatchRange.location > lastLoc) {
            NSRange outsideRange = NSMakeRange(lastLoc, fullMatchRange.location - lastLoc);
            NSString *outside = [raw substringWithRange:outsideRange];
            [parsed appendAttributedString:[[NSAttributedString alloc] initWithString:outside
                                                                           attributes:sAttrsWhite]];
        }

        // Append the span-inner text as blue.
        NSString *blue = [raw substringWithRange:innerRange];
        [parsed appendAttributedString:[[NSAttributedString alloc] initWithString:blue
                                                                       attributes:sAttrsBlue]];

        lastLoc = fullMatchRange.location + fullMatchRange.length;
    }

    if (lastLoc < raw.length) {
        NSRange trailingRange = NSMakeRange(lastLoc, raw.length - lastLoc);
        NSString *trailing = [raw substringWithRange:trailingRange];
        [parsed appendAttributedString:[[NSAttributedString alloc] initWithString:trailing
                                                                       attributes:sAttrsWhite]];
    }

    return [parsed copy];
}

#pragma mark - Process-Singleton Cache

+ (NSArray<NSAttributedString *> *)sharedFramesForBundle:(NSBundle *)bundle
{
    NSParameterAssert(bundle != nil);

    static dispatch_once_t once;
    static NSArray<NSAttributedString *> *cachedFrames = nil;
    dispatch_once(&once, ^{
        GhosttyFrameLoader *loader = [[GhosttyFrameLoader alloc] init];
        cachedFrames = [loader loadFramesFromBundle:bundle];
    });
    return cachedFrames;
}

@end
