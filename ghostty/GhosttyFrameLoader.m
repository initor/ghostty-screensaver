//
//  GhosttyFrameLoader.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/12/25.
//

#import "GhosttyFrameLoader.h"
#import "GhosttyColorScheme.h"
#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <os/signpost.h>

// File-level statics, populated once in +initialize. The font is shared by
// every attributed string in every scheme; the regexes compile once.
static NSFont *sMonospacedFont;
static NSRegularExpression *sSpanRegex;
static NSRegularExpression *sFilenameRegex;
static os_log_t sLog;
// Always-on signposts. OS_LOG_CATEGORY_POINTS_OF_INTEREST is auto-discovered
// by Instruments → Points of Interest and is a no-op cost when no client is
// attached, so always-on (vs DEBUG-gated) lets users diagnose field issues
// without a special build.
static os_log_t sPOILog;

// Process-wide cache: the last scheme loaded and its frames, plus geometry
// that depends on font and corpus only. Main thread only (see header).
static GhosttyColorScheme *sCachedScheme;
static NSArray<NSAttributedString *> *sCachedFrames;
static CGSize sCanvasSize;
static CGFloat sInkMidpoint;
static BOOL sGeometryReady;

@interface GhosttyFrameLoader ()
- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw
                                    bodyAttributes:(NSDictionary<NSAttributedStringKey, id> *)bodyAttributes
                                  accentAttributes:(NSDictionary<NSAttributedStringKey, id> *)accentAttributes;
+ (void)measureGeometryWithFrames:(NSArray<NSAttributedString *> *)frames;
@end

@implementation GhosttyFrameLoader

#pragma mark - One-Time Initialization

+ (void)initialize
{
    if (self != [GhosttyFrameLoader class]) {
        return;
    }

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

    sLog = os_log_create("com.initor.ghostty-screensaver", "FrameLoader");
    sPOILog = os_log_create("com.initor.ghostty-screensaver", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
}

#pragma mark - Public API

- (NSArray<NSAttributedString *> *)loadFramesFromBundle:(NSBundle *)bundle
                                                 scheme:(GhosttyColorScheme *)scheme
{
    NSParameterAssert(bundle != nil);
    NSParameterAssert(scheme != nil);

    os_signpost_id_t spid = os_signpost_id_generate(sPOILog);
    os_signpost_interval_begin(sPOILog, spid, "FrameLoad", "scheme=%{public}s", scheme.identifier.UTF8String);

    // Colors go in as CGColor under the Core Text key. CTFrameDraw then uses
    // them as they are; an NSColor under NSForegroundColorAttributeName is
    // converted through ColorSync on every run of every tick (39 percent of
    // CTFrameDraw time when measured). The font key is shared with Core Text.
    NSDictionary<NSAttributedStringKey, id> *bodyAttributes = @{
        NSFontAttributeName: sMonospacedFont,
        (__bridge NSAttributedStringKey)kCTForegroundColorAttributeName: (__bridge id)scheme.bodyColor,
    };
    NSDictionary<NSAttributedStringKey, id> *accentAttributes = @{
        (__bridge NSAttributedStringKey)kCTForegroundColorAttributeName: (__bridge id)scheme.accentColor,
    };

    NSDate *startDate = [NSDate date];
    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];

    // Frame filenames are zero-padded ("frame_001.txt" … "frame_235.txt")
    // so plain compare: produces correct lexicographic order, locale-
    // independently and ~2× faster than localizedStandardCompare:.
    paths = [paths sortedArrayUsingSelector:@selector(compare:)];

    NSMutableArray<NSAttributedString *> *loadedFrames = [NSMutableArray arrayWithCapacity:paths.count];
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
            // Fail-open: a corrupt or empty single frame should not blank the
            // whole screensaver. Log and continue. An empty frame would also
            // break the geometry pass, which reads attributes at index 0.
            if (rawContent.length == 0) {
                os_log_error(sLog, "Failed to read frame %{public}@ (%{public}@)",
                             basename,
                             rawContent ? @"empty" : (readError.localizedDescription ?: @"unknown"));
                skippedReadError++;
                continue;
            }

            [loadedFrames addObject:[self attributedFrameFromRawHTML:rawContent
                                                      bodyAttributes:bodyAttributes
                                                    accentAttributes:accentAttributes]];
        }
    }

    NSTimeInterval elapsedMs = [[NSDate date] timeIntervalSinceDate:startDate] * 1000.0;
    os_log_info(sLog,
                "Loaded %{public}lu frames for %{public}@ in %.1f ms (skipped: %{public}lu non-frame, %{public}lu read errors)",
                (unsigned long)loadedFrames.count,
                scheme.identifier,
                elapsedMs,
                (unsigned long)skippedNonFrame,
                (unsigned long)skippedReadError);

    os_signpost_interval_end(sPOILog, spid, "FrameLoad",
                             "count=%{public}lu elapsedMs=%.1f",
                             (unsigned long)loadedFrames.count,
                             elapsedMs);

    return [loadedFrames copy];
}

#pragma mark - Private Helpers

- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw
                                    bodyAttributes:(NSDictionary<NSAttributedStringKey, id> *)bodyAttributes
                                  accentAttributes:(NSDictionary<NSAttributedStringKey, id> *)accentAttributes
{
    // Two passes: strip the tags into one plain string while noting where
    // each accent run lands, then color the runs in place. One attributed
    // string plus ~160 addAttributes: calls is about 3× cheaper than
    // appending ~160 attributed pieces.
    NSArray<NSTextCheckingResult *> *matches =
        [sSpanRegex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];

    NSMutableString *plain = [NSMutableString stringWithCapacity:raw.length];
    NSMutableData *runs = [NSMutableData dataWithCapacity:matches.count * sizeof(NSRange)];
    NSUInteger lastLoc = 0;

    for (NSTextCheckingResult *match in matches) {
        NSRange fullMatchRange = [match rangeAtIndex:0];
        NSRange innerRange     = [match rangeAtIndex:1];

        if (fullMatchRange.location > lastLoc) {
            [plain appendString:[raw substringWithRange:NSMakeRange(lastLoc, fullMatchRange.location - lastLoc)]];
        }

        NSRange run = NSMakeRange(plain.length, innerRange.length);
        [plain appendString:[raw substringWithRange:innerRange]];
        [runs appendBytes:&run length:sizeof(run)];

        lastLoc = NSMaxRange(fullMatchRange);
    }

    if (lastLoc < raw.length) {
        [plain appendString:[raw substringFromIndex:lastLoc]];
    }

    NSMutableAttributedString *frame = [[NSMutableAttributedString alloc] initWithString:plain
                                                                              attributes:bodyAttributes];
    const NSRange *run = runs.bytes;
    NSUInteger runCount = runs.length / sizeof(NSRange);
    for (NSUInteger i = 0; i < runCount; i++) {
        [frame addAttributes:accentAttributes range:run[i]];
    }

    return [frame copy];
}

+ (void)measureGeometryWithFrames:(NSArray<NSAttributedString *> *)frames
{
    NSAttributedString *first = frames.firstObject;

    // Preserve the full 100-column canvas horizontally. The framesetter
    // omits trailing whitespace, whereas CTLine typographic width includes
    // it. Every bundled frame has the same 100-column, 41-row layout, so
    // the first frame stands for all of them.
    NSString *raw = first.string;
    NSRange firstNL = [raw rangeOfString:@"\n"];
    NSUInteger cols = (firstNL.location != NSNotFound) ? firstNL.location : raw.length;
    NSDictionary *probeAttrs = [first attributesAtIndex:0 effectiveRange:NULL];
    NSString *fullLine = [@"" stringByPaddingToLength:cols withString:@" " startingAtIndex:0];
    NSAttributedString *probe = [[NSAttributedString alloc] initWithString:fullLine attributes:probeAttrs];
    CTLineRef probeLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)probe);
    CGFloat trueWidth = CTLineGetTypographicBounds(probeLine, NULL, NULL, NULL);
    CFRelease(probeLine);

    CTFramesetterRef firstSetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)first);
    CGSize suggested = CTFramesetterSuggestFrameSizeWithConstraints(
        firstSetter, CFRangeMake(0, (CFIndex)first.length), NULL,
        CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX), NULL);
    CFRelease(firstSetter);

    CGSize canvas = CGSizeMake(trueWidth, suggested.height);

    // Union the visible ink of the entire loop so the anchor never shifts
    // when a character appears, disappears, or moves between frames. This
    // is the 80 ms pass that used to run once per view; now once per process.
    CGPathRef measurePath = CGPathCreateWithRect(CGRectMake(0, 0, canvas.width, canvas.height), NULL);
    CGRect ink = CGRectNull;
    for (NSAttributedString *frame in frames) {
        @autoreleasepool {
            CTFramesetterRef measureSetter = CTFramesetterCreateWithAttributedString(
                (__bridge CFAttributedStringRef)frame);
            CTFrameRef measureFrame = CTFramesetterCreateFrame(
                measureSetter, CFRangeMake(0, (CFIndex)frame.length), measurePath, NULL);
            CFArrayRef lines = CTFrameGetLines(measureFrame);
            for (CFIndex i = 0; i < CFArrayGetCount(lines); i++) {
                CTLineRef line = (CTLineRef)CFArrayGetValueAtIndex(lines, i);
                CGRect glyphs = CTLineGetImageBounds(line, NULL);
                if (!CGRectIsNull(glyphs) && !CGRectIsEmpty(glyphs)) {
                    CGPoint baseline;
                    CTFrameGetLineOrigins(measureFrame, CFRangeMake(i, 1), &baseline);
                    ink = CGRectUnion(ink, CGRectOffset(glyphs, baseline.x, baseline.y));
                }
            }
            CFRelease(measureFrame);
            CFRelease(measureSetter);
        }
    }
    CGPathRelease(measurePath);

    sCanvasSize = canvas;
    sInkMidpoint = CGRectIsNull(ink) ? canvas.height / 2.0 : CGRectGetMidY(ink);
    sGeometryReady = YES;

    os_log_info(sLog, "Canvas %.2fx%.2f pt, ink midpoint %.2f pt",
                canvas.width, canvas.height, sInkMidpoint);
}

#pragma mark - Process Cache

+ (NSArray<NSAttributedString *> *)framesForScheme:(GhosttyColorScheme *)scheme
                                            bundle:(NSBundle *)bundle
{
    NSParameterAssert(scheme != nil);
    NSParameterAssert(bundle != nil);
    NSAssert(NSThread.isMainThread, @"GhosttyFrameLoader is main-thread only");

    // Schemes are process singletons, so identity is the cache key.
    if (scheme == sCachedScheme && sCachedFrames.count > 0) {
        return sCachedFrames;
    }

    NSArray<NSAttributedString *> *frames =
        [[[GhosttyFrameLoader alloc] init] loadFramesFromBundle:bundle scheme:scheme];
    if (frames.count == 0) {
        return frames;
    }

    sCachedScheme = scheme;
    sCachedFrames = frames;
    if (!sGeometryReady) {
        [self measureGeometryWithFrames:frames];
    }
    return frames;
}

+ (CGSize)canvasSize
{
    return sCanvasSize;
}

+ (CGFloat)inkMidpoint
{
    return sInkMidpoint;
}

@end
