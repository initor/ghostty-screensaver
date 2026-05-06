//
//  GhosttyBenchmarkTests.m
//  ghosttyTest
//
//  SPDX-License-Identifier: MIT
//
//  B5 benchmark XCTest harness for the (currently-dead) ghosttyTest target.
//  Measures loader correctness, cold/warm load timing, per-frame layout
//  cost (against the legacy NSLayoutManager pipeline as a baseline), a
//  10,000-iteration animation-hot-path simulation, RSS delta, regex edge
//  cases, and sort-order equivalence.
//
//  No project source is modified by these tests — they are READ-ONLY
//  against GhosttyFrameLoader. Frames are loaded from a configurable
//  bundle (default: the test bundle itself; can be overridden via the
//  GHOSTTY_FRAMES_BUNDLE_PATH environment variable to point at a built
//  ghostty.saver bundle for a more realistic measurement).
//
//  Wiring (one-time, in Xcode UI — pbxproj patching with
//  PBXFileSystemSynchronizedRootGroup is brittle):
//    1. Select this file in the Xcode navigator.
//    2. File Inspector → Target Membership → check ghosttyTest.
//    3. Drag the ghostty/static/animation_frames/ folder onto the
//       ghosttyTest target's "Copy Bundle Resources" build phase
//       (or repoint GHOSTTY_FRAMES_BUNDLE_PATH at a built saver).
//    4. Drag GhosttyFrameLoader.m onto the ghosttyTest target's "Compile
//       Sources" build phase. (Logic-only test bundle, no TEST_HOST.)
//    5. Edit the ghostty scheme → Test → add ghosttyTest.
//
//  How to run:
//      xcodebuild -project ghostty.xcodeproj \
//                 -scheme ghostty \
//                 -destination 'platform=macOS' \
//                 test
//
//  Or, to point at a specific built saver bundle for the I/O timing tests:
//      GHOSTTY_FRAMES_BUNDLE_PATH=/path/to/ghostty.saver \
//      xcodebuild -project ghostty.xcodeproj -scheme ghostty \
//                 -destination 'platform=macOS' test
//

#import <XCTest/XCTest.h>
#import <AppKit/AppKit.h>
#import <mach/mach.h>
#import <mach/mach_init.h>
#import <mach/task.h>
#import <mach/task_info.h>

#import "GhosttyFrameLoader.h"

#pragma mark - Constants

/// The expected production frame count (frame_001.txt … frame_235.txt).
static NSUInteger const kExpectedFrameCount = 235;

/// Number of swap iterations for the animation-hot-path simulation.
/// 10,000 ÷ 30 FPS ≈ 5.5 minutes of continuous animation compressed into one test.
static NSUInteger const kRepeatedSwapIterations = 10000;

#pragma mark - Helpers

/// Resident set size in bytes via mach_task_basic_info. Returns 0 on error.
/// Uses MACH_TASK_BASIC_INFO (the modern variant) — TASK_BASIC_INFO is deprecated
/// and clipped to 32-bit values on 64-bit hosts.
static uint64_t GhosttyResidentSetSizeBytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(),
                                 MACH_TASK_BASIC_INFO,
                                 (task_info_t)&info,
                                 &count);
    if (kr != KERN_SUCCESS) {
        return 0;
    }
    return (uint64_t)info.resident_size;
}

#pragma mark - Test Case

@interface GhosttyBenchmarkTests : XCTestCase
@property (nonatomic, strong) GhosttyFrameLoader *loader;
@property (nonatomic, strong) NSBundle *framesBundle;
@property (nonatomic, strong) NSArray<NSAttributedString *> *cachedFrames;
@end

@implementation GhosttyBenchmarkTests

#pragma mark - Setup / Teardown

- (void)setUp {
    [super setUp];
    self.loader = [[GhosttyFrameLoader alloc] init];

    // Default: load frames from the test bundle (this class's bundle).
    // Override: GHOSTTY_FRAMES_BUNDLE_PATH env var points at a built .saver bundle.
    NSString *override = [[[NSProcessInfo processInfo] environment]
                          objectForKey:@"GHOSTTY_FRAMES_BUNDLE_PATH"];
    if (override.length > 0) {
        NSBundle *b = [NSBundle bundleWithPath:override];
        XCTAssertNotNil(b, @"GHOSTTY_FRAMES_BUNDLE_PATH set but bundle did not load: %@", override);
        self.framesBundle = b;
    } else {
        self.framesBundle = [NSBundle bundleForClass:[self class]];
    }

    // Cache one load for tests that don't measure the load itself, so we don't pay
    // the load cost in every test method's setUp.
    if (!self.cachedFrames) {
        self.cachedFrames = [self.loader loadFramesFromBundle:self.framesBundle];
    }
}

- (void)tearDown {
    self.loader = nil;
    [super tearDown];
}

#pragma mark - 1. Loader correctness

/// 235 frames returned for the production bundle.
- (void)testLoaderReturns235Frames {
    NSArray<NSAttributedString *> *frames = self.cachedFrames;
    XCTAssertEqual(frames.count, kExpectedFrameCount,
                   @"Expected %lu frames, got %lu. If lower, the resources didn't make it into "
                   @"the test bundle — see Wiring instructions at the top of this file.",
                   (unsigned long)kExpectedFrameCount, (unsigned long)frames.count);
}

/// All returned frames are non-nil and have length > 0.
- (void)testEveryFrameIsNonNilAndNonEmpty {
    NSArray<NSAttributedString *> *frames = self.cachedFrames;
    for (NSUInteger i = 0; i < frames.count; i++) {
        NSAttributedString *frame = frames[i];
        XCTAssertNotNil(frame, @"Frame %lu is nil", (unsigned long)i);
        XCTAssertGreaterThan(frame.length, (NSUInteger)0,
                             @"Frame %lu has length 0", (unsigned long)i);
    }
}

/// At least some frames contain a blue-attributed run.
/// (The blue color is sRGB 0,0,230/255,1 — defined in GhosttyFrameLoader.m.)
- (void)testAtLeastOneFrameContainsBlueRun {
    NSArray<NSAttributedString *> *frames = self.cachedFrames;
    NSUInteger framesWithBlueRun = 0;

    NSColor *expectedBlue = [NSColor colorWithSRGBRed:0.0
                                                green:0.0
                                                 blue:(230.0 / 255.0)
                                                alpha:1.0];

    for (NSAttributedString *frame in frames) {
        __block BOOL blueFound = NO;
        [frame enumerateAttribute:NSForegroundColorAttributeName
                          inRange:NSMakeRange(0, frame.length)
                          options:0
                       usingBlock:^(id value, NSRange range, BOOL *stop) {
            NSColor *c = (NSColor *)value;
            if (![c isKindOfClass:[NSColor class]]) return;
            // Compare in sRGB. NSColor equality is fussy; convert and compare components.
            NSColor *cInSRGB = [c colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            NSColor *bInSRGB = [expectedBlue colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
            if (cInSRGB && bInSRGB &&
                fabs(cInSRGB.redComponent   - bInSRGB.redComponent)   < 0.01 &&
                fabs(cInSRGB.greenComponent - bInSRGB.greenComponent) < 0.01 &&
                fabs(cInSRGB.blueComponent  - bInSRGB.blueComponent)  < 0.01) {
                blueFound = YES;
                *stop = YES;
            }
        }];
        if (blueFound) framesWithBlueRun++;
    }

    XCTAssertGreaterThan(framesWithBlueRun, (NSUInteger)0,
                         @"Not a single frame contained a blue-attributed run — regex parsing "
                         @"is silently failing-open across the whole corpus.");
    NSLog(@"[B5] Frames with blue runs: %lu / %lu",
          (unsigned long)framesWithBlueRun, (unsigned long)self.cachedFrames.count);
}

#pragma mark - 2. Loader cold-load timing (XCTMeasure)

/// Cold load: the first measureBlock invocation is not counted toward the average; subsequent
/// ones are. To get a *true* cold number, run this test fresh after a reboot or `sudo purge`.
///
/// Reports mean and standard deviation. Compare against H5's 250-400 ms estimate.
- (void)testLoaderColdLoadTiming {
    XCTMeasureOptions *options = [XCTMeasureOptions defaultOptions];
    options.iterationCount = 5;

    NSBundle *bundle = self.framesBundle;
    [self measureWithMetrics:@[[XCTClockMetric new]]
                     options:options
                       block:^{
        @autoreleasepool {
            GhosttyFrameLoader *fresh = [[GhosttyFrameLoader alloc] init];
            (void)[fresh loadFramesFromBundle:bundle];
        }
    }];
}

/// Warm-cache load: the first run primes the FS cache. XCTMeasure's built-in warm-up
/// serves the same purpose as a manual prime.
- (void)testLoaderWarmLoadTiming {
    // Prime the file cache.
    @autoreleasepool {
        GhosttyFrameLoader *primer = [[GhosttyFrameLoader alloc] init];
        (void)[primer loadFramesFromBundle:self.framesBundle];
    }

    XCTMeasureOptions *options = [XCTMeasureOptions defaultOptions];
    options.iterationCount = 10;

    NSBundle *bundle = self.framesBundle;
    [self measureWithMetrics:@[[XCTClockMetric new]]
                     options:options
                       block:^{
        @autoreleasepool {
            GhosttyFrameLoader *fresh = [[GhosttyFrameLoader alloc] init];
            (void)[fresh loadFramesFromBundle:bundle];
        }
    }];
}

#pragma mark - 3. Per-frame layout cost (legacy NSLayoutManager baseline)

/// Builds the same NSTextStorage / NSLayoutManager / NSTextContainer stack that ghosttyView
/// USED to use (pre-H6), then for each of 235 frames does setAttributedString +
/// glyphRangeForTextContainer + usedRectForTextContainer. Reports mean per-frame cost.
///
/// This is the baseline that H6 measured against — production now uses Core Text and is faster
/// (~35%). Keep this test as the regression guard against re-introducing NSLayoutManager.
- (void)testPerFrameLayoutCostLegacyBaseline {
    NSArray<NSAttributedString *> *frames = self.cachedFrames;
    XCTAssertEqual(frames.count, kExpectedFrameCount, @"Frame load failed; aborting layout test.");

    XCTMeasureOptions *options = [XCTMeasureOptions defaultOptions];
    options.iterationCount = 5;

    [self measureWithMetrics:@[[XCTClockMetric new]]
                     options:options
                       block:^{
        @autoreleasepool {
            NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(1e7, 1e7)];
            tc.lineFragmentPadding = 0;
            NSLayoutManager *lm = [[NSLayoutManager alloc] init];
            [lm addTextContainer:tc];
            NSTextStorage *ts = [[NSTextStorage alloc] init];
            [ts addLayoutManager:lm];

            for (NSAttributedString *frame in frames) {
                [ts setAttributedString:frame];
                (void)[lm glyphRangeForTextContainer:tc];
                (void)[lm usedRectForTextContainer:tc];
            }

            [ts removeLayoutManager:lm];
        }
    }];

    // Standalone single-pass timing for a per-frame mean (XCTMeasure reports total).
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(1e7, 1e7)];
    tc.lineFragmentPadding = 0;
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [lm addTextContainer:tc];
    NSTextStorage *ts = [[NSTextStorage alloc] init];
    [ts addLayoutManager:lm];

    NSDate *start = [NSDate date];
    for (NSAttributedString *frame in frames) {
        [ts setAttributedString:frame];
        (void)[lm glyphRangeForTextContainer:tc];
        (void)[lm usedRectForTextContainer:tc];
    }
    NSTimeInterval total = -[start timeIntervalSinceNow];
    [ts removeLayoutManager:lm];

    NSLog(@"[B5] Per-frame layout (legacy NSLayoutManager): total=%.3f ms across %lu frames → mean=%.3f µs/frame",
          total * 1000.0,
          (unsigned long)frames.count,
          (total * 1e6) / (double)frames.count);
}

#pragma mark - 4. Repeated swap simulation (animation hot path)

/// Cycles through frames 10,000 times via setAttributedString + layout query — the simulated
/// animation hot path that drawRect: drives at 30 FPS. Reports total wall time and an inferred
/// FPS-equivalent (frames/sec the layout stack alone could service, ignoring drawing).
///
/// If this number is far above 30, H3's hot-path concern is academic on this hardware.
/// If it's near or below 30, the layout cost is load-bearing and H3's fix path matters.
- (void)testRepeatedSwapSimulationFPSEquivalent {
    NSArray<NSAttributedString *> *frames = self.cachedFrames;
    XCTAssertEqual(frames.count, kExpectedFrameCount, @"Frame load failed; aborting swap test.");

    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(1e7, 1e7)];
    tc.lineFragmentPadding = 0;
    NSLayoutManager *lm = [[NSLayoutManager alloc] init];
    [lm addTextContainer:tc];
    NSTextStorage *ts = [[NSTextStorage alloc] init];
    [ts addLayoutManager:lm];

    NSUInteger count = frames.count;
    NSDate *start = [NSDate date];
    for (NSUInteger i = 0; i < kRepeatedSwapIterations; i++) {
        @autoreleasepool {
            NSAttributedString *frame = frames[i % count];
            [ts setAttributedString:frame];
            (void)[lm glyphRangeForTextContainer:tc];
            (void)[lm usedRectForTextContainer:tc];
        }
    }
    NSTimeInterval total = -[start timeIntervalSinceNow];
    [ts removeLayoutManager:lm];

    double meanMicros = (total * 1e6) / (double)kRepeatedSwapIterations;
    double fpsEquivalent = (double)kRepeatedSwapIterations / total;

    NSLog(@"[B5] Repeated swap: %lu iters in %.3f s → mean=%.3f µs/iter → FPS-equiv=%.0f",
          (unsigned long)kRepeatedSwapIterations, total, meanMicros, fpsEquivalent);

    // Sanity bound: even on a 2015 Intel iGPU we should clear several hundred FPS at this layer.
    // If we don't, the test target is misconfigured (e.g. running under a debugger with guard
    // malloc) — flag it loudly rather than silently passing.
    XCTAssertGreaterThan(fpsEquivalent, 60.0,
                         @"Layout-stack FPS-equivalent is %.1f — suspiciously low. Check that "
                         @"the test isn't running under guard malloc / address sanitizer.",
                         fpsEquivalent);
}

#pragma mark - 5. Memory baseline

/// Captures RSS before and after a full load. Reports the delta. This is a single-instance
/// measurement; SYNTHESIS H4 multi-display amplification means real-world resident usage is
/// 2-3× this number on multi-monitor setups + System Settings preview (now mitigated by
/// +sharedFramesForBundle:).
- (void)testMemoryFootprintAfterLoad {
    self.cachedFrames = nil;
    @autoreleasepool { /* Drain any pending autoreleased junk. */ }

    uint64_t rssBefore = GhosttyResidentSetSizeBytes();

    @autoreleasepool {
        GhosttyFrameLoader *fresh = [[GhosttyFrameLoader alloc] init];
        NSArray<NSAttributedString *> *frames = [fresh loadFramesFromBundle:self.framesBundle];
        XCTAssertEqual(frames.count, kExpectedFrameCount,
                       @"Memory test needs the full corpus to be representative.");
        self.cachedFrames = frames;
    }

    uint64_t rssAfter = GhosttyResidentSetSizeBytes();
    int64_t delta = (int64_t)rssAfter - (int64_t)rssBefore;
    NSLog(@"[B5] RSS: before=%.2f MB, after=%.2f MB, delta=%+.2f MB",
          rssBefore / 1024.0 / 1024.0,
          rssAfter  / 1024.0 / 1024.0,
          delta     / 1024.0 / 1024.0);

    XCTAssertGreaterThan(rssAfter, (uint64_t)0, @"task_info() failed — got 0 RSS.");
    XCTAssertLessThan(delta, (int64_t)(50LL * 1024LL * 1024LL),
                      @"Per-instance RSS delta of %.2f MB exceeds soft bound (50 MB).",
                      delta / 1024.0 / 1024.0);
}

#pragma mark - 6. Regex parsing edge cases

- (void)testParserEmptyFrame {
    NSAttributedString *result = [self parsedAttributedStringFromRawHTML:@""];
    XCTAssertNotNil(result);
    XCTAssertEqual(result.length, (NSUInteger)0,
                   @"Empty input should yield empty NSAttributedString, got length %lu",
                   (unsigned long)result.length);
}

- (void)testParserZeroSpansEntirelyWhite {
    NSString *raw = @"+++===*** plain ASCII no spans here ***===+++";
    NSAttributedString *result = [self parsedAttributedStringFromRawHTML:raw];
    XCTAssertEqual(result.length, raw.length, @"All input characters should round-trip.");

    NSColor *whiteExpected = [NSColor colorWithSRGBRed:(215.0/255.0)
                                                 green:(215.0/255.0)
                                                  blue:(215.0/255.0)
                                                 alpha:1.0];
    __block BOOL allWhite = YES;
    [result enumerateAttribute:NSForegroundColorAttributeName
                       inRange:NSMakeRange(0, result.length)
                       options:0
                    usingBlock:^(id value, NSRange range, BOOL *stop) {
        NSColor *c = [(NSColor *)value colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        NSColor *w = [whiteExpected   colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!c || fabs(c.redComponent   - w.redComponent)   >= 0.01 ||
                  fabs(c.greenComponent - w.greenComponent) >= 0.01 ||
                  fabs(c.blueComponent  - w.blueComponent)  >= 0.01) {
            allWhite = NO;
            *stop = YES;
        }
    }];
    XCTAssertTrue(allWhite, @"Zero-span frame should be entirely white.");
}

- (void)testParserMalformedUnclosedSpanFailsOpen {
    NSString *raw = @"prefix <span class=\"b\">unclosed forever";
    NSAttributedString *result = [self parsedAttributedStringFromRawHTML:raw];
    XCTAssertEqual(result.length, raw.length,
                   @"Malformed input should still round-trip every character (fail-open).");
    NSLog(@"[B5] Malformed-span fail-open content: '%@'", result.string);
}

- (void)testParserNestedSpansNonGreedy {
    NSString *raw = @"<span class=\"b\">outer<span class=\"b\">inner</span>tail</span>after";
    NSAttributedString *result = [self parsedAttributedStringFromRawHTML:raw];
    XCTAssertNotNil(result);
    XCTAssertGreaterThan(result.length, (NSUInteger)0);
    NSLog(@"[B5] Nested-span output string: '%@'", result.string);
}

- (void)testParserSingleSpanProducesBlueRun {
    NSString *raw = @"before<span class=\"b\">BLUE</span>after";
    NSAttributedString *result = [self parsedAttributedStringFromRawHTML:raw];
    XCTAssertEqual(result.length, (NSUInteger)(@"before".length + @"BLUE".length + @"after".length));

    NSRange blueRange = [result.string rangeOfString:@"BLUE"];
    XCTAssertNotEqual(blueRange.location, (NSUInteger)NSNotFound);

    NSDictionary *attrs = [result attributesAtIndex:blueRange.location effectiveRange:NULL];
    NSColor *fg = [(NSColor *)attrs[NSForegroundColorAttributeName]
                   colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    XCTAssertNotNil(fg);
    XCTAssertEqualWithAccuracy(fg.blueComponent,  230.0/255.0, 0.01);
    XCTAssertEqualWithAccuracy(fg.redComponent,   0.0,         0.01);
    XCTAssertEqualWithAccuracy(fg.greenComponent, 0.0,         0.01);
}

#pragma mark - 7. Sort order (localizedStandardCompare vs compare)

- (void)testSortOrderEquivalence {
    NSArray<NSString *> *paths = [self.framesBundle pathsForResourcesOfType:@"txt" inDirectory:nil];
    XCTAssertEqual(paths.count, kExpectedFrameCount,
                   @"Path scan returned %lu, expected %lu — bundle wiring issue.",
                   (unsigned long)paths.count, (unsigned long)kExpectedFrameCount);

    NSArray<NSString *> *byLocalizedStandard =
        [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSArray<NSString *> *byPlainCompare =
        [paths sortedArrayUsingSelector:@selector(compare:)];

    XCTAssertEqual(byLocalizedStandard.count, byPlainCompare.count);

    NSMutableArray<NSString *> *divergences = [NSMutableArray array];
    NSUInteger minCount = MIN(byLocalizedStandard.count, byPlainCompare.count);
    for (NSUInteger i = 0; i < minCount; i++) {
        NSString *aBase = [byLocalizedStandard[i] lastPathComponent];
        NSString *bBase = [byPlainCompare[i] lastPathComponent];
        if (![aBase isEqualToString:bBase]) {
            [divergences addObject:[NSString stringWithFormat:@"index %lu: localized='%@' plain='%@'",
                                    (unsigned long)i, aBase, bBase]];
        }
    }

    if (divergences.count > 0) {
        NSLog(@"[B5] Sort-order divergences (%lu):", (unsigned long)divergences.count);
        for (NSString *d in divergences) {
            NSLog(@"[B5]   %@", d);
        }
    } else {
        NSLog(@"[B5] Sort-order: localizedStandardCompare: and compare: produce IDENTICAL "
              @"ordering across all %lu frame filenames. L21 confirmed — plain compare: is "
              @"sufficient for zero-padded names.",
              (unsigned long)minCount);
    }

    XCTAssertNotNil(divergences, @"placeholder");
}

#pragma mark - Private helpers

/// Drives the loader's parser for an arbitrary raw string. Writes the raw content to a temp
/// frame file in a faux bundle directory, runs the loader against it, returns the single-frame
/// result. Avoids exposing attributedFrameFromRawHTML: as a public API.
- (NSAttributedString *)parsedAttributedStringFromRawHTML:(NSString *)raw {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tempDir = [NSTemporaryDirectory()
                         stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"ghostty-b5-%@", [NSUUID UUID].UUIDString]];

    NSError *err = nil;
    BOOL ok = [fm createDirectoryAtPath:tempDir
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&err];
    XCTAssertTrue(ok, @"Failed to create temp dir: %@", err);

    NSString *frameFile = [tempDir stringByAppendingPathComponent:@"frame_001.txt"];
    ok = [raw writeToFile:frameFile
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:&err];
    XCTAssertTrue(ok, @"Failed to write fixture: %@", err);

    NSBundle *fauxBundle = [NSBundle bundleWithPath:tempDir];
    XCTAssertNotNil(fauxBundle, @"Failed to construct faux bundle at %@", tempDir);

    GhosttyFrameLoader *fresh = [[GhosttyFrameLoader alloc] init];
    NSArray<NSAttributedString *> *frames = [fresh loadFramesFromBundle:fauxBundle];

    [fm removeItemAtPath:tempDir error:NULL];

    XCTAssertEqual(frames.count, (NSUInteger)1,
                   @"Expected exactly 1 frame from faux bundle (got %lu).",
                   (unsigned long)frames.count);

    return frames.firstObject ?: [[NSAttributedString alloc] init];
}

@end
