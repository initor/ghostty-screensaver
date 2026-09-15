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
static CTFrameRef Reference(NSAttributedString *text, NSRect bounds, NSSize *sizeOut,
                            NSPoint *originOut, NSString *label) CF_RETURNS_RETAINED;
static CTFrameRef Reference(NSAttributedString *text, NSRect bounds, NSSize *sizeOut,
                            NSPoint *originOut, NSString *label) {
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
    *sizeOut = size; *originOut = origin;
    CGPathRelease(path); CFRelease(fs);
    return frame;
}

static void TestFrame(ScreenSaverView *view, NSUInteger index, CGFloat scale, NSString *name,
                      BOOL save, NSMutableArray *samples) {
    NSString *label = [NSString stringWithFormat:@"%@ frame=%03lu scale=%.0f", name,
                       (unsigned long)index, scale];
    NSUInteger before = failures;
    NSArray *frames = [view valueForKey:@"frames"];
    Check([[view valueForKey:@"currentFrameIndex"] unsignedIntegerValue] == index,
          [label stringByAppendingString:@" animation index"]);
    NSSize expectedSize; NSPoint expectedOrigin;
    CTFrameRef reference = Reference(frames[index], view.bounds, &expectedSize, &expectedOrigin, label);
    NSBitmapImageRep *actual = Render(view, scale, NULL);
    NSBitmapImageRep *expected = Render(view, scale, reference);
    CFRelease(reference);
    NSSize actualSize = [[view valueForKey:@"cachedDrawSize"] sizeValue];
    NSPoint actualOrigin = [[view valueForKey:@"cachedDrawOrigin"] pointValue];
    Check(fabs(actualSize.width - expectedSize.width) < 0.01 &&
          fabs(actualSize.height - expectedSize.height) < 0.01 &&
          fabs(actualOrigin.x - expectedOrigin.x) < 0.01 &&
          fabs(actualOrigin.y - expectedOrigin.y) < 0.01,
          [NSString stringWithFormat:@"%@ canvas expected %@ at %@, got %@ at %@", label,
              NSStringFromSize(expectedSize), NSStringFromPoint(expectedOrigin),
              NSStringFromSize(actualSize), NSStringFromPoint(actualOrigin)]);
    NSDictionary *ink = Ink(actual), *referenceInk = Ink(expected);
    Check([ink[@"pixels"] unsignedIntegerValue] > 0 && [referenceInk[@"pixels"] unsignedIntegerValue] > 0,
          [label stringByAppendingString:@" nonblank actual and reference pixels"]);
    BOOL boxMatches = YES;
    for (NSString *key in @[@"left", @"right", @"top", @"bottom"]) {
        if (labs([ink[key] integerValue] - [referenceInk[key] integerValue]) > 1) boxMatches = NO;
    }
    Check(boxMatches, [NSString stringWithFormat:@"%@ ink bounds expected %@, got %@", label, referenceInk, ink]);
    NSUInteger different = PixelDifference(actual, expected);
    // Normalize by reference ink, not the mostly-black screen area. A missing row
    // or a 77-point translation must not disappear into a full-screen tolerance.
    NSUInteger allowed = MAX((NSUInteger)4, [referenceInk[@"pixels"] unsignedIntegerValue] / 1000);
    Check(different <= allowed,
          [NSString stringWithFormat:@"%@ full-frame pixel mismatch %lu (allowed %lu)", label,
              (unsigned long)different, (unsigned long)allowed]);
    // Keep PNG evidence bounded even when an old release fails every frame.
    // Every case still has structured failure details in results.json.
    if (save) {
        NSString *stem = [NSString stringWithFormat:@"%@-%03lu-%.0fx", name, (unsigned long)index, scale];
        SavePNG(actual, [stem stringByAppendingString:@"-actual.png"]);
        SavePNG(expected, [stem stringByAppendingString:@"-reference.png"]);
        [samples addObject:@{@"case": label, @"ink": ink, @"referenceInk": referenceInk,
            @"differentPixels": @(different), @"canvasSize": NSStringFromSize(actualSize),
            @"canvasOrigin": NSStringFromPoint(actualOrigin), @"passed": @(failures == before)}];
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "Usage: render_bundle /absolute/path/ghostty.saver /path/to/output-directory\n");
            return 2;
        }
        failureMessages = [NSMutableArray array];
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
                for (NSUInteger i = 0; i < 235; i++) {
                    @autoreleasepool {
                        TestFrame(view, i, 1, entry[0], i == 0 || i == 117 || i == 234, samples);
                        [view animateOneFrame];
                    }
                }
                Check([[view valueForKey:@"currentFrameIndex"] unsignedIntegerValue] == 0,
                      [NSString stringWithFormat:@"%@ wraps after 235 frames", entry[0]]);
            }
            ScreenSaverView *view = NewView(NSMakeRect(0, 0, 1512, 982), NO);
            if ([[view valueForKey:@"frames"] count] == 235) {
                for (NSUInteger i = 0; i < 235; i++) {
                    @autoreleasepool {
                        if (i == 0 || i == 117 || i == 234) TestFrame(view, i, 2, @"retina", YES, samples);
                        [view animateOneFrame];
                    }
                }
                NSBitmapImageRep *first = Render(view, 1, NULL);
                NSBitmapImageRep *second = Render(view, 1, NULL);
                Check(PixelDifference(first, second) == 0, @"same-frame repeat render is identical");
                [view setFrame:NSMakeRect(0, 0, 1920, 1080)];
                TestFrame(view, 0, 1, @"resize-frame", YES, samples);
                [view setBoundsSize:NSMakeSize(1600, 1000)];
                TestFrame(view, 0, 1, @"resize-bounds", YES, samples);
                [view setBoundsOrigin:NSMakePoint(19, -13)];
                TestFrame(view, 0, 1, @"translate-bounds", YES, samples);
                ScreenSaverView *fresh = NewView(view.bounds, NO);
                Check(PixelDifference(Render(view, 1, NULL), Render(fresh, 1, NULL)) == 0,
                      @"same-index bounds changes match fresh view");
                [fresh stopAnimation]; [fresh startAnimation];
                TestFrame(fresh, 0, 1, @"restart", YES, samples);
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
