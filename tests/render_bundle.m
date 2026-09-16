// SPDX-License-Identifier: MIT
// Native rendering checks against a loaded saver binary, not linked source copies.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <CoreText/CoreText.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSUInteger failures, checks;
static NSMutableArray<NSString *> *failureMessages;
static NSString *outputDirectory;
static NSBundle *saverBundle;
static NSMutableDictionary<NSNumber *, NSNumber *> *referenceCycleMidpoints;
static NSMutableArray<NSDictionary *> *cycleResults;

static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) {
        failures++;
        [failureMessages addObject:message];
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

static ScreenSaverView *NewView(NSRect bounds, BOOL preview) {
    Class cls = saverBundle.principalClass;
    ScreenSaverView *view = [[cls alloc] initWithFrame:NSMakeRect(0, 0, bounds.size.width, bounds.size.height)
                                          isPreview:preview];
    view.bounds = bounds;
    return view;
}

static NSString *SHA256(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *s = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [s appendFormat:@"%02x", digest[i]];
    return s;
}

// Explicit RGBA/sRGB allocation keeps scan order, alpha, color space, and scale fixed.
static NSBitmapImageRep *Bitmap(NSSize size, CGFloat scale) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)llround(size.width * scale)
        pixelsHigh:(NSInteger)llround(size.height * scale) bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace
        bitmapFormat:0 bytesPerRow:0 bitsPerPixel:32];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace];
    rep.size = size;
    return rep;
}

static NSBitmapImageRep *Render(ScreenSaverView *view, CGFloat scale, CTFrameRef reference) {
    NSRect bounds = view.bounds;
    NSBitmapImageRep *rep = Bitmap(bounds.size, scale);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rep.bitmapData, rep.pixelsWide, rep.pixelsHigh,
        8, rep.bytesPerRow, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!ctx) [NSException raise:@"BitmapContext" format:@"Cannot create RGBA context"];
    NSGraphicsContext *graphics = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:NO];
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = graphics;
    CGContextSaveGState(ctx);
    // Install our own point-to-pixel transform instead of depending on AppKit's
    // implicit bitmap size/backing-scale conventions.
    CGContextConcatCTM(ctx, CGAffineTransformInvert(CGContextGetCTM(ctx)));
    CGContextScaleCTM(ctx, scale, scale);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, bounds.size.width, bounds.size.height));
    CGContextTranslateCTM(ctx, -bounds.origin.x, -bounds.origin.y);
    CGContextClipToRect(ctx, bounds);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    if (reference) {
        // Draw the reference line-by-line rather than invoking the saver's draw code.
        CFArrayRef lines = CTFrameGetLines(reference);
        CFIndex count = CFArrayGetCount(lines);
        CGPoint *origins = calloc((size_t)count, sizeof(CGPoint));
        CTFrameGetLineOrigins(reference, CFRangeMake(0, 0), origins);
        CGRect path = CGPathGetBoundingBox(CTFrameGetPath(reference));
        for (CFIndex i = 0; i < count; i++) {
            CGContextSetTextPosition(ctx, path.origin.x + origins[i].x, path.origin.y + origins[i].y);
            CTLineDraw((CTLineRef)CFArrayGetValueAtIndex(lines, i), ctx);
        }
        free(origins);
    } else {
        // A detached layer-backed view does not reliably service displayIfNeeded.
        // Calling the real override with an explicit context exercises its renderer.
        [view drawRect:bounds];
    }
    CGContextRestoreGState(ctx);
    [graphics flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
    CGContextRelease(ctx);
    return rep;
}

static NSDictionary *Ink(NSBitmapImageRep *rep) {
    NSInteger left = rep.pixelsWide, right = -1, top = rep.pixelsHigh, bottom = -1;
    NSUInteger count = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        unsigned char *row = rep.bitmapData + y * rep.bytesPerRow;
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            unsigned char *p = row + 4 * x;
            if (MAX(p[0], MAX(p[1], p[2])) > 8) {
                left = MIN(left, x); right = MAX(right, x);
                top = MIN(top, y); bottom = MAX(bottom, y); count++;
            }
        }
    }
    return @{@"pixels": @(count), @"left": @(left), @"right": @(right),
             @"top": @(top), @"bottom": @(bottom)};
}

static NSUInteger PixelDifference(NSBitmapImageRep *a, NSBitmapImageRep *b) {
    NSUInteger different = 0;
    for (NSInteger y = 0; y < a.pixelsHigh; y++) {
        unsigned char *ar = a.bitmapData + y * a.bytesPerRow;
        unsigned char *br = b.bitmapData + y * b.bytesPerRow;
        for (NSInteger x = 0; x < a.pixelsWide; x++) {
            BOOL differs = NO;
            for (NSUInteger c = 0; c < 4; c++) {
                if (abs((int)ar[x * 4 + c] - (int)br[x * 4 + c]) > 4) differs = YES;
            }
            different += differs;
        }
    }
    return different;
}

static void SavePNG(NSBitmapImageRep *rep, NSString *name) {
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSError *error = nil;
    Check(png && [png writeToFile:[outputDirectory stringByAppendingPathComponent:name]
                         options:NSDataWritingAtomic error:&error],
          [NSString stringWithFormat:@"write %@: %@", name, error ?: @"PNG encode failed"]);
}

// Measure every real line, including its trailing spaces. This oracle does not
// reuse the saver's first-line all-space probe or cached size/origin calculation.
static CTFrameRef Reference(NSAttributedString *text, NSRect bounds, CGFloat scale,
                            NSSize *sizeOut, NSPoint *originOut, NSSize *inkSizeOut,
                            CGFloat cycleMidpoint, NSString *label) CF_RETURNS_RETAINED;
static CTFrameRef Reference(NSAttributedString *text, NSRect bounds, CGFloat scale,
                            NSSize *sizeOut, NSPoint *originOut, NSSize *inkSizeOut,
                            CGFloat cycleMidpoint, NSString *label) {
    NSArray<NSString *> *lines = [text.string componentsSeparatedByString:@"\n"];
    NSUInteger lineCount = lines.count;
    if ([lines.lastObject length] == 0) lineCount--;
    Check(lineCount == 41, [label stringByAppendingString:@" expected 41 corpus lines"]);
    CGFloat width = 0;
    NSUInteger location = 0;
    for (NSUInteger i = 0; i < lineCount; i++) {
        NSUInteger length = [lines[i] length];
        Check(length == 100, [label stringByAppendingString:@" expected 100 corpus columns"]);
        NSAttributedString *line = [text attributedSubstringFromRange:NSMakeRange(location, length)];
        CTLineRef ctLine = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)line);
        width = MAX(width, CTLineGetTypographicBounds(ctLine, NULL, NULL, NULL));
        CFRelease(ctLine);
        location += length + 1;
    }
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    CGSize suggested = CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRangeMake(0, text.length),
        NULL, CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX), NULL);
    NSSize size = NSMakeSize(width, suggested.height);
    NSPoint origin = NSMakePoint(NSMidX(bounds) - size.width / 2, NSMidY(bounds) - size.height / 2);
    CGPathRef path = CGPathCreateWithRect(NSMakeRect(origin.x, origin.y, size.width, size.height), NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, text.length), path, NULL);
    CFRange visible = CTFrameGetVisibleStringRange(frame);
    NSUInteger meaningfulEnd = text.length;
    while (meaningfulEnd && [[NSCharacterSet whitespaceAndNewlineCharacterSet]
        characterIsMember:[text.string characterAtIndex:meaningfulEnd - 1]]) meaningfulEnd--;
    Check(visible.location == 0 && visible.length >= (CFIndex)meaningfulEnd,
          [label stringByAppendingString:@" reference must fit every nonblank character"]);
    Check(CFArrayGetCount(CTFrameGetLines(frame)) == (CFIndex)lineCount,
          [label stringByAppendingString:@" reference must retain all rows without wrapping"]);
    // Rasterize all rows with generous margins. The placement oracle measures
    // pixels only, never CTLineGetImageBounds or the saver's cached origin.
    NSSize canvas = NSMakeSize(ceil(size.width) + 128, ceil(size.height) + 128);
    ScreenSaverView *probe = [[ScreenSaverView alloc]
        initWithFrame:NSMakeRect(0, 0, canvas.width, canvas.height) isPreview:NO];
    CGPathRelease(path); CFRelease(frame);
    NSPoint probeOrigin = NSMakePoint(64, 64);
    path = CGPathCreateWithRect(NSMakeRect(probeOrigin.x, probeOrigin.y, size.width, size.height), NULL);
    frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, text.length), path, NULL);
    NSBitmapImageRep *raster = Render(probe, scale, frame);
    NSDictionary *ink = Ink(raster);
    Check([ink[@"pixels"] unsignedIntegerValue] > 0, [label stringByAppendingString:@" generous reference has ink"]);
    Check([ink[@"left"] integerValue] > 0 && [ink[@"right"] integerValue] < raster.pixelsWide - 1 &&
          [ink[@"top"] integerValue] > 0 && [ink[@"bottom"] integerValue] < raster.pixelsHigh - 1,
          [label stringByAppendingString:@" generous reference has unclipped ink"]);
    CGFloat centerPixel = ([ink[@"top"] doubleValue] + [ink[@"bottom"] doubleValue] + 1) / 2;
    // Calibrate raw bitmap row orientation rather than assuming top-down storage.
    static CGFloat rowDirection;
    if (!rowDirection) {
        CGPathRef shiftedPath = CGPathCreateWithRect(NSMakeRect(64, 65, size.width, size.height), NULL);
        CTFrameRef shifted = CTFramesetterCreateFrame(fs, CFRangeMake(0, text.length), shiftedPath, NULL);
        NSDictionary *shiftInk = Ink(Render(probe, scale, shifted));
        CGFloat shiftCenter = ([shiftInk[@"top"] doubleValue] + [shiftInk[@"bottom"] doubleValue] + 1) / 2;
        rowDirection = (shiftCenter - centerPixel) / scale;
        Check(fabs(fabs(rowDirection) - 1) < 0.001, @"bitmap row orientation calibrates to one point");
        CFRelease(shifted); CGPathRelease(shiftedPath);
    }
    CGFloat correction = (raster.pixelsHigh / 2.0 - centerPixel) / (rowDirection * scale);
    CGFloat localInkCenter = canvas.height / 2 - (probeOrigin.y + correction);
    origin.y = NSMidY(bounds) - (isnan(cycleMidpoint) ? localInkCenter : cycleMidpoint);
    *inkSizeOut = NSMakeSize(([ink[@"right"] doubleValue] - [ink[@"left"] doubleValue] + 1) / scale,
                            ([ink[@"bottom"] doubleValue] - [ink[@"top"] doubleValue] + 1) / scale);
    CGPathRelease(path); CFRelease(frame);
    path = CGPathCreateWithRect(NSMakeRect(origin.x, origin.y, size.width, size.height), NULL);
    frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, text.length), path, NULL);
    *sizeOut = size; *originOut = origin;
    CGPathRelease(path); CFRelease(fs);
    return frame;
}

// Union independent pixel extents in one canonical layout, once per scale.
static CGFloat ReferenceCycleMidpoint(NSArray<NSAttributedString *> *frames, CGFloat scale) {
    NSNumber *cached = referenceCycleMidpoints[@(scale)];
    if (cached) return cached.doubleValue;
    CGFloat minimum = CGFLOAT_MAX, maximum = -CGFLOAT_MAX;
    NSRect bounds = NSMakeRect(0, 0, 1920, 1080);
    for (NSAttributedString *text in frames) {
        @autoreleasepool {
            NSSize size, inkSize; NSPoint origin;
            CTFrameRef frame = Reference(text, bounds, scale, &size, &origin, &inkSize,
                                         NAN, @"cycle raster probe");
            CGFloat midpoint = NSMidY(bounds) - origin.y;
            minimum = MIN(minimum, midpoint - inkSize.height / 2);
            maximum = MAX(maximum, midpoint + inkSize.height / 2);
            CFRelease(frame);
        }
    }
    CGFloat midpoint = (minimum + maximum) / 2;
    referenceCycleMidpoints[@(scale)] = @(midpoint);
    return midpoint;
}

static void TestFrame(ScreenSaverView *view, NSUInteger index, CGFloat scale, NSString *name,
                      BOOL save, NSMutableArray *samples) {
    NSString *label = [NSString stringWithFormat:@"%@ frame=%03lu scale=%.0f", name,
                       (unsigned long)index, scale];
    NSUInteger before = failures;
    NSArray *frames = [view valueForKey:@"frames"];
    Check([[view valueForKey:@"currentFrameIndex"] unsignedIntegerValue] == index,
          [label stringByAppendingString:@" animation index"]);
    NSSize expectedSize, completeInkSize; NSPoint expectedOrigin;
    CTFrameRef reference = Reference(frames[index], view.bounds, scale, &expectedSize, &expectedOrigin,
                                     &completeInkSize, ReferenceCycleMidpoint(frames, scale), label);
    NSBitmapImageRep *actual = Render(view, scale, NULL);
    NSBitmapImageRep *expected = Render(view, scale, reference);
    CFRelease(reference);
    NSSize actualSize = [[view valueForKey:@"cachedDrawSize"] sizeValue];
    NSPoint actualOrigin = [[view valueForKey:@"cachedDrawOrigin"] pointValue];
    Check(fabs(actualSize.width - expectedSize.width) < 0.01 &&
          fabs(actualSize.height - expectedSize.height) < 0.01 &&
          fabs(actualOrigin.x - expectedOrigin.x) < 0.01,
          [NSString stringWithFormat:@"%@ canvas expected %@ at %@, got %@ at %@", label,
              NSStringFromSize(expectedSize), NSStringFromPoint(expectedOrigin),
              NSStringFromSize(actualSize), NSStringFromPoint(actualOrigin)]);
    NSDictionary *ink = Ink(actual), *referenceInk = Ink(expected);
    Check([ink[@"pixels"] unsignedIntegerValue] > 0 && [referenceInk[@"pixels"] unsignedIntegerValue] > 0,
          [label stringByAppendingString:@" nonblank actual and reference pixels"]);
    BOOL fullScreen = ![name hasPrefix:@"preview-clipped"];
    Check(fabs(actualOrigin.y - expectedOrigin.y) <= 1.0,
          [label stringByAppendingString:@" origin matches independent cycle raster envelope within 1 pt"]);
    if (fullScreen) {
        CGFloat inkWidth = ([ink[@"right"] doubleValue] - [ink[@"left"] doubleValue] + 1) / scale;
        CGFloat inkHeight = ([ink[@"bottom"] doubleValue] - [ink[@"top"] doubleValue] + 1) / scale;
        Check(fabs(inkWidth - completeInkSize.width) <= 2 / scale &&
              fabs(inkHeight - completeInkSize.height) <= 2 / scale,
              [label stringByAppendingString:@" full-screen retains complete unclipped artwork dimensions"]);
        Check([ink[@"left"] integerValue] > 0 && [ink[@"right"] integerValue] < actual.pixelsWide - 1 &&
              [ink[@"top"] integerValue] > 0 && [ink[@"bottom"] integerValue] < actual.pixelsHigh - 1,
              [label stringByAppendingString:@" full-screen artwork has clear edges"]);
    }
    // Content oracle keeps the independently measured X, but follows the actual
    // Y translation so fractional raster phase cannot mask a missing glyph/row.
    // Cycle centering is checked independently from the union of actual pixels.
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)frames[index]);
    CGPathRef alignedPath = CGPathCreateWithRect(NSMakeRect(expectedOrigin.x, actualOrigin.y,
        expectedSize.width, expectedSize.height), NULL);
    CTFrameRef alignedFrame = CTFramesetterCreateFrame(fs, CFRangeMake(0, [frames[index] length]), alignedPath, NULL);
    NSBitmapImageRep *aligned = Render(view, scale, alignedFrame);
    CFRelease(alignedFrame); CGPathRelease(alignedPath); CFRelease(fs);
    NSDictionary *alignedInk = Ink(aligned);
    BOOL boxMatches = YES;
    for (NSString *key in @[@"left", @"right", @"top", @"bottom"]) {
        if (labs([ink[key] integerValue] - [alignedInk[key] integerValue]) > 1) boxMatches = NO;
    }
    Check(boxMatches, [NSString stringWithFormat:@"%@ aligned content bounds expected %@, got %@", label, alignedInk, ink]);
    NSUInteger different = PixelDifference(actual, aligned);
    // Normalize by reference ink, not the mostly-black screen area. A missing row
    // or a 77-point translation must not disappear into a full-screen tolerance.
    NSUInteger allowed = MAX((NSUInteger)4, [alignedInk[@"pixels"] unsignedIntegerValue] / 1000);
    Check(different <= allowed,
          [NSString stringWithFormat:@"%@ full-frame pixel mismatch %lu (allowed %lu)", label,
              (unsigned long)different, (unsigned long)allowed]);
    if (save) {
        NSString *stem = [NSString stringWithFormat:@"%@-%03lu-%.0fx", name, (unsigned long)index, scale];
        SavePNG(actual, [stem stringByAppendingString:@"-actual.png"]);
        SavePNG(expected, [stem stringByAppendingString:@"-reference.png"]);
    }
    [samples addObject:@{@"case": label, @"ink": ink, @"referenceInk": referenceInk,
        @"originY": @(actualOrigin.y), @"expectedOriginY": @(expectedOrigin.y),
        @"completeInkSize": NSStringFromSize(completeInkSize),
        @"differentPixels": @(different), @"canvasSize": NSStringFromSize(actualSize),
        @"canvasOrigin": NSStringFromPoint(actualOrigin), @"passed": @(failures == before)}];
}

static void TestCycle(ScreenSaverView *view, CGFloat scale, NSString *name, NSMutableArray *samples) {
    CGFloat firstOrigin = 0, previousOrigin = 0, maximumStep = 0;
    NSInteger top = NSIntegerMax, bottom = -1;
    NSInteger referenceTop = NSIntegerMax, referenceBottom = -1;
    for (NSUInteger i = 0; i < 235; i++) {
        @autoreleasepool {
            TestFrame(view, i, scale, name, i == 0 || i == 117 || i == 234, samples);
            NSDictionary *sample = samples.lastObject;
            CGFloat origin = [sample[@"originY"] doubleValue];
            if (i == 0) firstOrigin = previousOrigin = origin;
            CGFloat step = fabs(origin - previousOrigin);
            maximumStep = MAX(maximumStep, step);
            Check(fabs(origin - firstOrigin) <= 0.000001 && step <= 0.000001,
                  [NSString stringWithFormat:@"%@ frame=%lu stable origin and zero step (%.6f pt)",
                   name, (unsigned long)i, step]);
            previousOrigin = origin;
            top = MIN(top, [sample[@"ink"][@"top"] integerValue]);
            bottom = MAX(bottom, [sample[@"ink"][@"bottom"] integerValue]);
            referenceTop = MIN(referenceTop, [sample[@"referenceInk"][@"top"] integerValue]);
            referenceBottom = MAX(referenceBottom, [sample[@"referenceInk"][@"bottom"] integerValue]);
            [view animateOneFrame];
        }
    }
    Check([[view valueForKey:@"currentFrameIndex"] unsignedIntegerValue] == 0,
          [name stringByAppendingString:@" wraps after 235 frames"]);
    TestFrame(view, 0, scale, [name stringByAppendingString:@"-wrap"], NO, samples);
    CGFloat wrapOrigin = [samples.lastObject[@"originY"] doubleValue];
    CGFloat wrapStep = fabs(wrapOrigin - previousOrigin);
    maximumStep = MAX(maximumStep, wrapStep);
    Check(fabs(wrapOrigin - firstOrigin) <= 0.000001 && wrapStep <= 0.000001,
          [name stringByAppendingString:@" cyclic wrap preserves origin and zero step"]);
    BOOL fullScreen = ![name hasPrefix:@"preview-clipped"];
    CGFloat pixelsHigh = llround(view.bounds.size.height * scale);
    CGFloat error = fabs((top + bottom + 1 - pixelsHigh) / (2 * scale));
    CGFloat referenceError = fabs((referenceTop + referenceBottom + 1 - pixelsHigh) / (2 * scale));
    if (fullScreen) {
        Check(error <= 1.0, [NSString stringWithFormat:@"%@ whole-cycle pixel union center error %.3f pt exceeds 1 pt", name, error]);
        Check(referenceError <= 1.0, [name stringByAppendingString:@" independent whole-cycle raster union is centered"]);
    }
    [cycleResults addObject:@{@"case": name, @"scale": @(scale), @"frames": @235,
        @"originY": @(firstOrigin), @"maximumOriginStepPoints": @(maximumStep),
        @"verticalCenterErrorPoints": @(error), @"referenceVerticalCenterErrorPoints": @(referenceError),
        @"centeringRequired": @(fullScreen)}];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: render_bundle /absolute/path/ghostty.saver /path/to/output-directory\n");
            return 2;
        }
        failureMessages = [NSMutableArray array];
        referenceCycleMidpoints = [NSMutableDictionary dictionary];
        cycleResults = [NSMutableArray array];
        outputDirectory = [[NSString stringWithUTF8String:argv[2]] stringByStandardizingPath];
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:outputDirectory
                withIntermediateDirectories:YES attributes:nil error:&error]) {
            fprintf(stderr, "Cannot create output directory: %s\n", error.description.UTF8String); return 2;
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        saverBundle = [NSBundle bundleWithPath:[[NSString stringWithUTF8String:argv[1]] stringByStandardizingPath]];
        if (!saverBundle || ![saverBundle loadAndReturnError:&error] ||
            ![saverBundle.principalClass isSubclassOfClass:ScreenSaverView.class]) {
            fprintf(stderr, "Cannot load ScreenSaverView bundle: %s\n", error.description.UTF8String ?: "invalid principal class");
            return 2;
        }
        if (![[NSBundle bundleForClass:saverBundle.principalClass].bundlePath isEqual:saverBundle.bundlePath]) {
            fprintf(stderr, "Principal class belongs to another bundle; run one saver per process.\n"); return 2;
        }
        NSMutableArray *samples = [NSMutableArray array];
        @try {
            ScreenSaverView *corpusView = NewView(NSMakeRect(0, 0, 1920, 1080), NO);
            NSArray<NSAttributedString *> *loaded = [corpusView valueForKey:@"frames"];
            NSArray<NSString *> *paths = [saverBundle pathsForResourcesOfType:@"txt" inDirectory:nil];
            NSPredicate *frameName = [NSPredicate predicateWithBlock:^BOOL(NSString *path, NSDictionary *bindings) {
                (void)bindings;
                return [[path lastPathComponent] hasPrefix:@"frame_"];
            }];
            paths = [[paths filteredArrayUsingPredicate:frameName] sortedArrayUsingSelector:@selector(compare:)];
            Check(paths.count == 235 && loaded.count == 235, @"bundle and loader each contain 235 frames");
            NSRegularExpression *spans = [NSRegularExpression regularExpressionWithPattern:@"<span class=\\\"b\\\">(.*?)</span>"
                options:NSRegularExpressionDotMatchesLineSeparators error:&error];
            for (NSUInteger i = 0; i < MIN(paths.count, loaded.count); i++) {
                NSString *expectedName = [NSString stringWithFormat:@"frame_%03lu.txt", (unsigned long)i + 1];
                Check([[paths[i] lastPathComponent] isEqual:expectedName],
                      [NSString stringWithFormat:@"resource order %@", expectedName]);
                NSString *raw = [NSString stringWithContentsOfFile:paths[i] encoding:NSUTF8StringEncoding error:&error];
                NSString *plain = raw ? [spans stringByReplacingMatchesInString:raw options:0
                    range:NSMakeRange(0, raw.length) withTemplate:@"$1"] : nil;
                Check(plain && [loaded[i].string isEqual:plain],
                      [NSString stringWithFormat:@"loaded frame %lu matches bundled %@", (unsigned long)i, expectedName]);
            }
            NSArray *cases = @[
                @[@"landscape", @1920, @1080, @NO],
                @[@"laptop", @1512, @982, @NO],
                @[@"portrait", @1080, @1920, @NO],
                @[@"odd-bounds", @1601, @1001, @NO],
                @[@"preview-clipped", @800, @600, @YES]
            ];
            for (NSArray *entry in cases) {
                ScreenSaverView *view = NewView(NSMakeRect(0, 0, [entry[1] doubleValue], [entry[2] doubleValue]), [entry[3] boolValue]);
                NSArray *frames = [view valueForKey:@"frames"];
                Check(frames.count == 235, [NSString stringWithFormat:@"%@ loaded 235 frames", entry[0]]);
                if (frames.count != 235) continue;
                TestCycle(view, 1, entry[0], samples);
            }
            ScreenSaverView *view = NewView(NSMakeRect(0, 0, 1512, 982), NO);
            if ([[view valueForKey:@"frames"] count] == 235) {
                TestCycle(view, 2, @"retina", samples);
                NSBitmapImageRep *first = Render(view, 1, NULL);
                NSBitmapImageRep *second = Render(view, 1, NULL);
                Check(PixelDifference(first, second) == 0, @"same-frame repeat render is identical");
                CGFloat localMidpoint = NSMidY(view.bounds) - [[view valueForKey:@"cachedDrawOrigin"] pointValue].y;
                [view setFrame:NSMakeRect(0, 0, 1920, 1080)];
                TestFrame(view, 0, 1, @"resize-frame", YES, samples);
                Check(fabs(NSMidY(view.bounds) - [[view valueForKey:@"cachedDrawOrigin"] pointValue].y - localMidpoint) <= 0.000001,
                      @"frame resize preserves cycle midpoint");
                [view setBoundsSize:NSMakeSize(1600, 1000)];
                TestFrame(view, 0, 1, @"resize-bounds", YES, samples);
                Check(fabs(NSMidY(view.bounds) - [[view valueForKey:@"cachedDrawOrigin"] pointValue].y - localMidpoint) <= 0.000001,
                      @"bounds resize preserves cycle midpoint");
                [view setBoundsOrigin:NSMakePoint(19, -13)];
                TestFrame(view, 0, 1, @"translate-bounds", YES, samples);
                Check(fabs(NSMidY(view.bounds) - [[view valueForKey:@"cachedDrawOrigin"] pointValue].y - localMidpoint) <= 0.000001,
                      @"bounds translation preserves cycle midpoint");
                ScreenSaverView *fresh = NewView(view.bounds, NO);
                Check(PixelDifference(Render(view, 1, NULL), Render(fresh, 1, NULL)) == 0,
                      @"same-index bounds changes match fresh view");
                [fresh stopAnimation]; [fresh startAnimation];
                TestFrame(fresh, 0, 1, @"restart", YES, samples);
                Check(fabs(NSMidY(fresh.bounds) - [[fresh valueForKey:@"cachedDrawOrigin"] pointValue].y - localMidpoint) <= 0.000001,
                      @"restart preserves cycle midpoint");
                [fresh stopAnimation];
            }
        } @catch (NSException *exception) {
            Check(NO, [NSString stringWithFormat:@"exception %@: %@", exception.name, exception.reason]);
        }
        NSData *binary = [NSData dataWithContentsOfFile:saverBundle.executablePath];
        NSDictionary *report = @{
            @"bundle": saverBundle.bundlePath, @"executableSHA256": binary ? SHA256(binary) : @"unreadable",
            @"bundleVersion": saverBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown",
            @"bundleBuild": saverBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown",
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"checks": @(checks), @"failures": @(failures), @"passed": @(failures == 0),
            @"failureMessages": failureMessages, @"samples": samples,
            @"cycles": cycleResults,
            @"scope": @"Actual bundle drawRect into explicit bitmap; not WindowServer/ScreenSaverEngine composition."
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
        if (![json writeToFile:[outputDirectory stringByAppendingPathComponent:@"results.json"]
                      options:NSDataWritingAtomic error:&error]) {
            fprintf(stderr, "Cannot write results: %s\n", error.description.UTF8String); return 2;
        }
        printf("%s: %lu checks, %lu failures. Evidence: %s\n", failures ? "FAIL" : "PASS",
               (unsigned long)checks, (unsigned long)failures, outputDirectory.UTF8String);
        return failures ? 1 : 0;
    }
}
