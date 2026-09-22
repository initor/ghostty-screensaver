// SPDX-License-Identifier: MIT
// Native rendering checks against a loaded saver binary, not linked source copies.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <CoreText/CoreText.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <math.h>

static NSUInteger failures, checks;
static NSMutableArray<NSString *> *failureMessages;
static NSString *outputDirectory;
static NSBundle *saverBundle;
static NSMutableDictionary<NSString *, NSNumber *> *referenceCycleMidpoints;
static NSMutableArray<NSDictionary *> *cycleResults;
static NSMutableArray<NSDictionary *> *schemeResults;

// The harness's own copy of the scheme contract (ghostty/GhosttyColorScheme.m).
// Ids, popup order, display names and colors are asserted against the bundle,
// so a drift on either side fails here instead of shipping.
typedef struct { const char *identifier; const char *displayName; unsigned bg, body, accent; unsigned gradient[4]; } SchemeSpec;
static const SchemeSpec kSchemes[] = {
    { "classic",              "Classic",              0x000000, 0xd7d7d7, 0x0000e6, { 0, 0, 0, 0 } },
    { "catppuccin-frappe",    "Catppuccin Frappé",    0x303446, 0xc6d0f5, 0x8caaee, { 0xef9f76, 0xf4b8e4, 0xca9ee6, 0x8caaee } },
    { "catppuccin-macchiato", "Catppuccin Macchiato", 0x24273a, 0xcad3f5, 0x8aadf4, { 0xf5a97f, 0xf5bde6, 0xc6a0f6, 0x8aadf4 } },
    { "catppuccin-mocha",     "Catppuccin Mocha",     0x1e1e2e, 0xcdd6f4, 0x89b4fa, { 0xfab387, 0xf5c2e7, 0xcba6f7, 0x89b4fa } },
};
static const NSUInteger kSchemeCount = sizeof(kSchemes) / sizeof(kSchemes[0]);
static const NSUInteger kRows = 41;

static BOOL HasGradient(const SchemeSpec *s) { return s->gradient[0] || s->gradient[1] || s->gradient[2] || s->gradient[3]; }

// The gradient oracle, recomputed here from the documented formula in
// GhosttyColorScheme.h, in the same integer arithmetic: R = rows - 1,
// k = min(2, 3 row / R), n = 3 row - R k, component = (A (R - n) + B n) / R
// rounded half up.
static unsigned RowColor(const SchemeSpec *s, NSUInteger row) {
    if (!HasGradient(s)) return s->body;
    unsigned span = (unsigned)(kRows - 1);
    unsigned k = MIN(2u, (unsigned)(3 * row) / span);
    unsigned n = (unsigned)(3 * row) - span * k;
    unsigned rgb = 0;
    for (NSUInteger i = 0; i < 3; i++) {
        unsigned shift = (unsigned)(16 - 8 * i);
        unsigned a = (s->gradient[k] >> shift) & 0xff, b = (s->gradient[k + 1] >> shift) & 0xff;
        unsigned numerator = a * (span - n) + b * n;
        rgb |= ((2 * numerator + span) / (2 * span)) << shift;
    }
    return rgb;
}

// Bitmap row direction per point of view y, calibrated once in Reference():
// -1 when moving content up in view space lowers the bitmap row index.
static CGFloat gRowDirection;
// The scheme every view created from here on gets, and the background every
// raster is filled with. The harness never reads or writes ScreenSaverDefaults:
// outside the sandbox a write would land in the developer's own preferences.
static const SchemeSpec *gScheme = &kSchemes[0];
// Fit rule from GhosttyView.drawRect:, recomputed here as an oracle.
static const CGFloat kFitMargin = 0.08;

static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) {
        failures++;
        [failureMessages addObject:message];
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    }
}

static void SelectScheme(const char *identifier) {
    for (NSUInteger i = 0; i < kSchemeCount; i++) {
        if (!strcmp(kSchemes[i].identifier, identifier)) { gScheme = &kSchemes[i]; return; }
    }
    Check(NO, [NSString stringWithFormat:@"unknown harness scheme %s", identifier]);
}

static id LookupScheme(NSString *identifier) {
    Class schemeClass = NSClassFromString(@"GhosttyColorScheme");
    id scheme = [schemeClass performSelector:@selector(schemeWithIdentifier:) withObject:identifier];
    Check(scheme != nil, [@"scheme lookup " stringByAppendingString:identifier]);
    return scheme;
}

// The same entry point the Options sheet drives; never touches preferences.
static void ApplyScheme(ScreenSaverView *view, const char *identifier) {
    [view performSelector:@selector(applyScheme:) withObject:LookupScheme(@(identifier))];
}

static ScreenSaverView *NewView(NSRect bounds, BOOL preview) {
    Class cls = saverBundle.principalClass;
    ScreenSaverView *view = [[cls alloc] initWithFrame:NSMakeRect(0, 0, bounds.size.width, bounds.size.height)
                                          isPreview:preview];
    view.bounds = bounds;
    ApplyScheme(view, gScheme->identifier);
    return view;
}

static CGFloat ExpectedFit(NSRect bounds, NSSize canvas) {
    if (MIN(bounds.size.width / canvas.width, bounds.size.height / canvas.height) >= 1) return 1;
    CGFloat margin = kFitMargin * MIN(bounds.size.width, bounds.size.height);
    CGFloat fit = MIN((bounds.size.width - 2 * margin) / canvas.width,
                      (bounds.size.height - 2 * margin) / canvas.height);
    return MIN(1.0, MAX(fit, 0.01));
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

// `fit` scales a reference render about the bounds center exactly as the saver
// does for small bounds. The saver path (reference == NULL) applies its own.
static NSBitmapImageRep *Render(ScreenSaverView *view, CGFloat scale, CTFrameRef reference, CGFloat fit) {
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
    // The layer background the saver relies on, from the harness's own table.
    CGContextSetRGBFillColor(ctx, ((gScheme->bg >> 16) & 0xff) / 255.0,
                             ((gScheme->bg >> 8) & 0xff) / 255.0, (gScheme->bg & 0xff) / 255.0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, bounds.size.width, bounds.size.height));
    CGContextTranslateCTM(ctx, -bounds.origin.x, -bounds.origin.y);
    CGContextClipToRect(ctx, bounds);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    if (reference) {
        // Draw the reference line-by-line rather than invoking the saver's draw code.
        if (fit < 1) {
            CGContextTranslateCTM(ctx, NSMidX(bounds), NSMidY(bounds));
            CGContextScaleCTM(ctx, fit, fit);
            CGContextTranslateCTM(ctx, -NSMidX(bounds), -NSMidY(bounds));
        }
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

// Ink is any pixel whose largest channel distance from the scheme background
// exceeds 8, so light schemes measure the same way as black.
static NSDictionary *Ink(NSBitmapImageRep *rep) {
    int bg[3] = { (int)((gScheme->bg >> 16) & 0xff), (int)((gScheme->bg >> 8) & 0xff), (int)(gScheme->bg & 0xff) };
    NSInteger left = rep.pixelsWide, right = -1, top = rep.pixelsHigh, bottom = -1;
    NSUInteger count = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        unsigned char *row = rep.bitmapData + y * rep.bytesPerRow;
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            unsigned char *p = row + 4 * x;
            int d = MAX(abs((int)p[0] - bg[0]), MAX(abs((int)p[1] - bg[1]), abs((int)p[2] - bg[2])));
            if (d > 8) {
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

// Pixels whose sRGB value equals `rgb` exactly, and their mean bitmap row.
static NSUInteger ExactPixelsMeanY(NSBitmapImageRep *rep, unsigned rgb, double *meanY) {
    unsigned char want[3] = { (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff };
    NSUInteger count = 0; double sumY = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) {
        unsigned char *row = rep.bitmapData + y * rep.bytesPerRow;
        for (NSInteger x = 0; x < rep.pixelsWide; x++) {
            unsigned char *p = row + 4 * x;
            if (p[0] == want[0] && p[1] == want[1] && p[2] == want[2]) { count++; sumY += y; }
        }
    }
    if (meanY) *meanY = count ? sumY / count : 0;
    return count;
}
static NSUInteger ExactPixels(NSBitmapImageRep *rep, unsigned rgb) { return ExactPixelsMeanY(rep, rgb, NULL); }

static BOOL LayerBackgroundIs(ScreenSaverView *view, unsigned rgb) {
    CGColorRef color = view.layer.backgroundColor;
    if (!color || CGColorGetNumberOfComponents(color) < 3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return fabs(c[0] * 255 - ((rgb >> 16) & 0xff)) < 0.5 &&
           fabs(c[1] * 255 - ((rgb >> 8) & 0xff)) < 0.5 &&
           fabs(c[2] * 255 - (rgb & 0xff)) < 0.5;
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
    NSBitmapImageRep *raster = Render(probe, scale, frame, 1);
    NSDictionary *ink = Ink(raster);
    Check([ink[@"pixels"] unsignedIntegerValue] > 0, [label stringByAppendingString:@" generous reference has ink"]);
    Check([ink[@"left"] integerValue] > 0 && [ink[@"right"] integerValue] < raster.pixelsWide - 1 &&
          [ink[@"top"] integerValue] > 0 && [ink[@"bottom"] integerValue] < raster.pixelsHigh - 1,
          [label stringByAppendingString:@" generous reference has unclipped ink"]);
    CGFloat centerPixel = ([ink[@"top"] doubleValue] + [ink[@"bottom"] doubleValue] + 1) / 2;
    // Calibrate raw bitmap row orientation rather than assuming top-down storage.
    CGFloat rowDirection = gRowDirection;
    if (!rowDirection) {
        CGPathRef shiftedPath = CGPathCreateWithRect(NSMakeRect(64, 65, size.width, size.height), NULL);
        CTFrameRef shifted = CTFramesetterCreateFrame(fs, CFRangeMake(0, text.length), shiftedPath, NULL);
        NSDictionary *shiftInk = Ink(Render(probe, scale, shifted, 1));
        CGFloat shiftCenter = ([shiftInk[@"top"] doubleValue] + [shiftInk[@"bottom"] doubleValue] + 1) / 2;
        rowDirection = (shiftCenter - centerPixel) / scale;
        gRowDirection = rowDirection;
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

// Union independent pixel extents in one canonical layout, once per scale and scheme.
static CGFloat ReferenceCycleMidpoint(NSArray<NSAttributedString *> *frames, CGFloat scale) {
    NSString *key = [NSString stringWithFormat:@"%s@%g", gScheme->identifier, scale];
    NSNumber *cached = referenceCycleMidpoints[key];
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
    referenceCycleMidpoints[key] = @(midpoint);
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
    // The fit oracle: full-screen cases must not scale, small bounds must.
    BOOL fullScreen = ![name hasPrefix:@"preview-fit"];
    CGFloat expectedFit = ExpectedFit(view.bounds, expectedSize);
    Check(fullScreen ? expectedFit == 1.0 : expectedFit < 1.0,
          [NSString stringWithFormat:@"%@ fit oracle %.4f matches case kind", label, expectedFit]);
    NSBitmapImageRep *actual = Render(view, scale, NULL, 1);
    NSBitmapImageRep *expected = Render(view, scale, reference, expectedFit);
    CFRelease(reference);
    NSSize actualSize = [[view valueForKey:@"cachedDrawSize"] sizeValue];
    NSPoint actualOrigin = [[view valueForKey:@"cachedDrawOrigin"] pointValue];
    CGFloat actualFit = [[view valueForKey:@"cachedFit"] doubleValue];
    Check(fabs(actualSize.width - expectedSize.width) < 0.01 &&
          fabs(actualSize.height - expectedSize.height) < 0.01 &&
          fabs(actualOrigin.x - expectedOrigin.x) < 0.01,
          [NSString stringWithFormat:@"%@ canvas expected %@ at %@, got %@ at %@", label,
              NSStringFromSize(expectedSize), NSStringFromPoint(expectedOrigin),
              NSStringFromSize(actualSize), NSStringFromPoint(actualOrigin)]);
    Check(fabs(actualFit - expectedFit) < 0.000001,
          [NSString stringWithFormat:@"%@ fit expected %.6f, got %.6f", label, expectedFit, actualFit]);
    NSDictionary *ink = Ink(actual), *referenceInk = Ink(expected);
    Check([ink[@"pixels"] unsignedIntegerValue] > 0 && [referenceInk[@"pixels"] unsignedIntegerValue] > 0,
          [label stringByAppendingString:@" nonblank actual and reference pixels"]);
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
    } else {
        // Scaled to fit: the whole ghost is inside the bounds with a visible margin.
        NSInteger clear = (NSInteger)llround(4 * scale);
        Check([ink[@"left"] integerValue] >= clear && [ink[@"right"] integerValue] < actual.pixelsWide - clear &&
              [ink[@"top"] integerValue] >= clear && [ink[@"bottom"] integerValue] < actual.pixelsHigh - clear,
              [NSString stringWithFormat:@"%@ fitted artwork keeps a clear edge (ink %@)", label, ink]);
    }
    // Content oracle keeps the independently measured X, but follows the actual
    // Y translation so fractional raster phase cannot mask a missing glyph/row.
    // Cycle centering is checked independently from the union of actual pixels.
    CTFramesetterRef fs = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)frames[index]);
    CGPathRef alignedPath = CGPathCreateWithRect(NSMakeRect(expectedOrigin.x, actualOrigin.y,
        expectedSize.width, expectedSize.height), NULL);
    CTFrameRef alignedFrame = CTFramesetterCreateFrame(fs, CFRangeMake(0, [frames[index] length]), alignedPath, NULL);
    NSBitmapImageRep *aligned = Render(view, scale, alignedFrame, expectedFit);
    CFRelease(alignedFrame); CGPathRelease(alignedPath); CFRelease(fs);
    NSDictionary *alignedInk = Ink(aligned);
    BOOL boxMatches = YES;
    for (NSString *key in @[@"left", @"right", @"top", @"bottom"]) {
        if (labs([ink[key] integerValue] - [alignedInk[key] integerValue]) > 1) boxMatches = NO;
    }
    Check(boxMatches, [NSString stringWithFormat:@"%@ aligned content bounds expected %@, got %@", label, alignedInk, ink]);
    NSUInteger different = PixelDifference(actual, aligned);
    // Normalize by reference ink, not the mostly-background screen area. A missing
    // row or a 77-point translation must not disappear into a full-screen tolerance.
    NSUInteger allowed = MAX((NSUInteger)4, [alignedInk[@"pixels"] unsignedIntegerValue] / 1000);
    Check(different <= allowed,
          [NSString stringWithFormat:@"%@ full-frame pixel mismatch %lu (allowed %lu)", label,
              (unsigned long)different, (unsigned long)allowed]);
    if (save) {
        NSString *stem = [NSString stringWithFormat:@"%@-%03lu-%.0fx", name, (unsigned long)index, scale];
        SavePNG(actual, [stem stringByAppendingString:@"-actual.png"]);
        SavePNG(expected, [stem stringByAppendingString:@"-reference.png"]);
    }
    [samples addObject:@{@"case": label, @"scheme": @(gScheme->identifier), @"ink": ink, @"referenceInk": referenceInk,
        @"originY": @(actualOrigin.y), @"expectedOriginY": @(expectedOrigin.y), @"fit": @(actualFit),
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
    BOOL fullScreen = ![name hasPrefix:@"preview-fit"];
    CGFloat pixelsHigh = llround(view.bounds.size.height * scale);
    CGFloat error = fabs((top + bottom + 1 - pixelsHigh) / (2 * scale));
    CGFloat referenceError = fabs((referenceTop + referenceBottom + 1 - pixelsHigh) / (2 * scale));
    if (fullScreen) {
        Check(error <= 1.0, [NSString stringWithFormat:@"%@ whole-cycle pixel union center error %.3f pt exceeds 1 pt", name, error]);
        Check(referenceError <= 1.0, [name stringByAppendingString:@" independent whole-cycle raster union is centered"]);
    }
    [cycleResults addObject:@{@"case": name, @"scheme": @(gScheme->identifier), @"scale": @(scale), @"frames": @235,
        @"originY": @(firstOrigin), @"maximumOriginStepPoints": @(maximumStep),
        @"verticalCenterErrorPoints": @(error), @"referenceVerticalCenterErrorPoints": @(referenceError),
        @"centeringRequired": @(fullScreen)}];
}

static void TestFrameAttributes(NSAttributedString *frame, NSString *label);

// Every scheme draws its own three colors and nobody else's. Ranking the most
// common colors does not work at 1x: antialiased shades of the body outrank
// the thin accent halo. Exact counts do (measured minima 12,057 body and
// 2,161 accent on frames 1 and 117 at 1920x1080).
static void TestSchemeColors(void) {
    for (NSUInteger s = 0; s < kSchemeCount; s++) {
        SelectScheme(kSchemes[s].identifier);
        ScreenSaverView *view = NewView(NSMakeRect(0, 0, 1920, 1080), NO);
        NSString *name = [NSString stringWithFormat:@"scheme-%s", gScheme->identifier];
        Check(LayerBackgroundIs(view, gScheme->bg), [name stringByAppendingString:@" layer background"]);
        for (NSNumber *index in @[@0, @117]) {
            [view setValue:index forKey:@"currentFrameIndex"];
            NSBitmapImageRep *rep = Render(view, 1, NULL, 1);
            NSString *label = [NSString stringWithFormat:@"%@ frame=%03d", name, index.intValue];
            unsigned char *corner = rep.bitmapData;
            Check(corner[0] == ((gScheme->bg >> 16) & 0xff) && corner[1] == ((gScheme->bg >> 8) & 0xff) &&
                  corner[2] == (gScheme->bg & 0xff), [label stringByAppendingString:@" corner pixel is the background"]);
            // Body pixels: the flat color, or the sum over the gradient rows.
            // Each row's exact pixels must also sit in that row's band of the
            // bitmap, so a reversed or shifted gradient fails here and not
            // only in the attribute check. The bottom row's color equals the
            // accent in every flavor, so the halo is never gradient evidence.
            NSUInteger body = 0, rowsPresent = 0;
            if (HasGradient(gScheme)) {
                NSSize canvas = [[view valueForKey:@"cachedDrawSize"] sizeValue];
                NSPoint origin = [[view valueForKey:@"cachedDrawOrigin"] pointValue];
                double lineHeight = canvas.height / kRows;
                for (NSUInteger row = 0; row < kRows; row++) {
                    unsigned color = RowColor(gScheme, row);
                    if (color == gScheme->accent) continue;
                    double meanY = 0;
                    NSUInteger n = ExactPixelsMeanY(rep, color, &meanY);
                    body += n;
                    if (n < 50) continue;
                    rowsPresent++;
                    double rowCenter = origin.y + canvas.height - ((double)row + 0.5) * lineHeight;
                    double expectedY = rep.pixelsHigh / 2.0 + gRowDirection * (rowCenter - NSMidY(view.bounds));
                    Check(fabs(meanY - expectedY) <= lineHeight / 2,
                          [NSString stringWithFormat:@"%@ row %lu color #%06x sits in its band (mean y %.1f, expected %.1f)",
                           label, (unsigned long)row, color, meanY, expectedY]);
                }
                // Measured at 1x on frames 0 and 117: 27 (Frappé), 23 (Macchiato), 25 (Mocha).
                // Rows fall under 50 exact pixels only through antialiasing of sparse rows.
                Check(rowsPresent >= 20, [NSString stringWithFormat:@"%@ %lu of %lu gradient rows draw at least 50 exact pixels in their band",
                                          label, (unsigned long)rowsPresent, (unsigned long)kRows]);
                Check(ExactPixels(rep, gScheme->body) == 0,
                      [label stringByAppendingString:@" gradient scheme draws no pixel of its flat body color"]);
            } else {
                body = ExactPixels(rep, gScheme->body);
            }
            NSUInteger accent = ExactPixels(rep, gScheme->accent);
            Check(body >= 10000, [NSString stringWithFormat:@"%@ exact body pixels %lu >= 10000", label, (unsigned long)body]);
            Check(accent >= 1000, [NSString stringWithFormat:@"%@ exact accent pixels %lu >= 1000", label, (unsigned long)accent]);
            Check(body > accent, [NSString stringWithFormat:@"%@ body pixels %lu outnumber accent pixels %lu", label,
                                  (unsigned long)body, (unsigned long)accent]);
            TestFrameAttributes([view valueForKey:@"frames"][index.unsignedIntegerValue], label);
            for (NSUInteger o = 0; o < kSchemeCount; o++) {
                if (o == s) continue;
                NSUInteger foreign = ExactPixels(rep, kSchemes[o].accent);
                Check(foreign == 0, [NSString stringWithFormat:@"%@ draws %lu pixels of %s accent", label,
                                     (unsigned long)foreign, kSchemes[o].identifier]);
            }
            if (index.intValue == 117) SavePNG(rep, [name stringByAppendingString:@"-117-1x.png"]);
            [schemeResults addObject:@{@"scheme": @(gScheme->identifier), @"frame": index,
                @"bodyPixels": @(body), @"accentPixels": @(accent)}];
        }
    }
    SelectScheme("classic");
}

// Exact CGColor components under the Core Text key, and no AppKit color key:
// the perf change depends on CTFrameDraw never converting an NSColor per run.
static BOOL AttributesCarry(NSDictionary *attrs, unsigned rgb) {
    id value = attrs[(__bridge NSString *)kCTForegroundColorAttributeName];
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CGColorGetTypeID()) return NO;
    if (attrs[NSForegroundColorAttributeName]) return NO;
    CGColorRef color = (__bridge CGColorRef)value;
    if (CGColorGetNumberOfComponents(color) < 3) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return fabs(c[0] * 255 - ((rgb >> 16) & 0xff)) < 0.5 && fabs(c[1] * 255 - ((rgb >> 8) & 0xff)) < 0.5 &&
           fabs(c[2] * 255 - (rgb & 0xff)) < 0.5;
}

static void TestFrameAttributes(NSAttributedString *frame, NSString *label) {
    Check(AttributesCarry([frame attributesAtIndex:0 effectiveRange:NULL], RowColor(gScheme, 0)),
          [label stringByAppendingString:@" first run carries the row 0 body CGColor under the Core Text key"]);
    // Every run is the accent or the body color of the row it sits on.
    NSString *text = frame.string;
    __block NSUInteger accentRuns = 0, otherRuns = 0;
    [frame enumerateAttributesInRange:NSMakeRange(0, frame.length) options:0
                           usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        (void)stop;
        NSUInteger row = [[text substringToIndex:range.location] componentsSeparatedByString:@"\n"].count - 1;
        // Accent first: the bottom row's gradient color equals the accent.
        if (AttributesCarry(attrs, gScheme->accent)) { accentRuns++; return; }
        if (AttributesCarry(attrs, RowColor(gScheme, MIN(row, kRows - 1)))) return;
        otherRuns++;
    }];
    Check(accentRuns > 0 && otherRuns == 0,
          [NSString stringWithFormat:@"%@ %lu accent runs carry the accent CGColor, %lu runs carry something else",
           label, (unsigned long)accentRuns, (unsigned long)otherRuns]);
}

// The lookup contract: table order, and every missing or unknown value
// resolves to the first row. Goes through the loaded class only.
static void TestSchemeLookup(void) {
    Class schemeClass = NSClassFromString(@"GhosttyColorScheme");
    NSArray *all = [schemeClass performSelector:@selector(allSchemes)];
    Check(all.count == kSchemeCount, [NSString stringWithFormat:@"lookup: %lu schemes in the table", (unsigned long)all.count]);
    for (NSUInteger i = 0; i < kSchemeCount && i < all.count; i++) {
        Check([[all[i] valueForKey:@"identifier"] isEqual:@(kSchemes[i].identifier)] &&
              [[all[i] valueForKey:@"displayName"] isEqual:@(kSchemes[i].displayName)],
              [NSString stringWithFormat:@"lookup: row %lu is %s", (unsigned long)i, kSchemes[i].identifier]);
        Check(LookupScheme(@(kSchemes[i].identifier)) == all[i],
              [NSString stringWithFormat:@"lookup: %s resolves to its table object", kSchemes[i].identifier]);
    }
    NSDictionary<NSString *, NSString *> *cases = @{
        @"": @"classic", @"   ": @"classic", @"not-a-scheme": @"classic", @"CLASSIC": @"classic",
        @"  Catppuccin-Mocha \n": @"catppuccin-mocha", @"catppuccin-latte": @"classic",
    };
    for (NSString *input in cases) {
        id scheme = LookupScheme(input);
        Check([[scheme valueForKey:@"identifier"] isEqual:cases[input]],
              [NSString stringWithFormat:@"lookup: '%@' resolves to %@", input, cases[input]]);
    }
    id fallback = [schemeClass performSelector:@selector(schemeWithIdentifier:) withObject:nil];
    Check(fallback == all.firstObject && [[fallback valueForKey:@"identifier"] isEqual:@"classic"],
          @"lookup: nil resolves to the first row, classic");
}

static NSView *FindSubview(NSView *root, Class cls, NSString *title) {
    if ([root isKindOfClass:cls] && (!title || [[(NSButton *)root title] isEqual:title])) return root;
    for (NSView *child in root.subviews) {
        NSView *found = FindSubview(child, cls, title);
        if (found) return found;
    }
    return nil;
}

// The Options sheet is the only new UI. Drive it without showing it: popup
// changes must reach the view live, Cancel must restore. OK is never sent
// because it would write the developer's real preferences.
static void TestOptionsSheet(void) {
    SelectScheme("classic");
    ScreenSaverView *view = NewView(NSMakeRect(0, 0, 800, 600), YES);
    Check(view.hasConfigureSheet, @"sheet: hasConfigureSheet");
    NSWindow *window = view.configureSheet;
    Check(window != nil, @"sheet: configureSheet returns a window");
    Check(view.configureSheet == window, @"sheet: window is reused across requests");
    Check(!window.releasedWhenClosed, @"sheet: window survives close");
    NSPopUpButton *popup = (NSPopUpButton *)FindSubview(window.contentView, NSPopUpButton.class, nil);
    Check(popup != nil, @"sheet: one popup");
    if (!popup) return;
    Check(popup.numberOfItems == (NSInteger)kSchemeCount,
          [NSString stringWithFormat:@"sheet: %ld popup items", (long)popup.numberOfItems]);
    for (NSUInteger i = 0; i < kSchemeCount && (NSInteger)i < popup.numberOfItems; i++) {
        Check([[popup itemTitleAtIndex:(NSInteger)i] isEqual:@(kSchemes[i].displayName)],
              [NSString stringWithFormat:@"sheet: item %lu is %s", (unsigned long)i, kSchemes[i].displayName]);
    }
    Check(popup.indexOfSelectedItem == 0, @"sheet: opens on the current scheme");
    NSArray *before = [view valueForKey:@"frames"];
    for (NSUInteger i = 1; i < kSchemeCount && (NSInteger)i < popup.numberOfItems; i++) {
        [popup selectItemAtIndex:(NSInteger)i];
        [popup sendAction:popup.action to:popup.target];
        Check(LayerBackgroundIs(view, kSchemes[i].bg),
              [NSString stringWithFormat:@"sheet: selecting %s updates the view live", kSchemes[i].identifier]);
        NSArray *after = [view valueForKey:@"frames"];
        Check(after != before, [NSString stringWithFormat:@"sheet: %s swaps the frames", kSchemes[i].identifier]);
        before = after;
    }
    NSButton *cancel = (NSButton *)FindSubview(window.contentView, NSButton.class, @"Cancel");
    Check(cancel != nil, @"sheet: Cancel button");
    if (cancel) [cancel sendAction:cancel.action to:cancel.target];
    Check(LayerBackgroundIs(view, kSchemes[0].bg), @"sheet: Cancel restores the opening scheme");
    Check([view.configureSheet isEqual:window] && popup.indexOfSelectedItem == 0,
          @"sheet: reopening selects the restored scheme");
    Check(FindSubview(window.contentView, NSButton.class, @"OK") != nil, @"sheet: OK button");
}

// On macOS 14 to 26 the host stays resident, starts a new view on every
// activation and never stops the old one (issue #6). The newest full-screen
// view on a screen must be the only one drawing, whichever of "start" and
// "add to a window" the host does last. Smaller views, views on no screen
// and detached views take no part. A restarted view takes over again. The
// windows are never shown.
static void TestSupersededViews(void) {
    NSScreen *screen = NSScreen.mainScreen;
    Check(screen != nil, @"stale: a screen to place windows on");
    if (!screen) return;
    SelectScheme("classic");
    NSRect full = screen.frame;
    NSMutableArray<NSWindow *> *windows = [NSMutableArray array];
    void (^place)(ScreenSaverView *, NSRect) = ^(ScreenSaverView *view, NSRect frame) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.releasedWhenClosed = NO;
        [windows addObject:window];
        [window.contentView addSubview:view];
    };
    BOOL (^retired)(ScreenSaverView *) = ^BOOL(ScreenSaverView *view) {
        return [[view valueForKey:@"retired"] boolValue];
    };
    BOOL (^draws)(ScreenSaverView *) = ^BOOL(ScreenSaverView *view) {
        NSBitmapImageRep *rep = Render(view, 1, NULL, 1);
        return ExactPixels(rep, gScheme->bg) < (NSUInteger)(rep.pixelsWide * rep.pixelsHigh);
    };
    ScreenSaverView *first = NewView(full, NO);
    place(first, full);
    [first startAnimation];
    Check(!retired(first) && first.isAnimating && draws(first), @"stale: the first full-screen view draws");

    ScreenSaverView *second = NewView(full, NO);
    place(second, full);
    [second startAnimation];
    Check(retired(first) && !first.isAnimating && first.isHidden && !draws(first),
          @"stale: a newer full-screen view retires the older one on its screen");
    Check(!retired(second) && second.isAnimating && draws(second), @"stale: the newer view draws");

    ScreenSaverView *small = NewView(NSMakeRect(0, 0, 800, 600), NO);
    place(small, NSMakeRect(full.origin.x, full.origin.y, 800, 600));
    [small startAnimation];
    Check(!retired(small) && !retired(second), @"stale: a smaller view neither retires nor is retired");

    ScreenSaverView *offscreen = NewView(full, NO);
    place(offscreen, NSOffsetRect(full, 0, -4 * full.size.height));
    [offscreen startAnimation];
    Check(!retired(offscreen) && !retired(second), @"stale: a view on no screen neither retires nor is retired");

    ScreenSaverView *late = NewView(full, NO);
    [late startAnimation];
    Check(!retired(second) && !retired(late), @"stale: a view started outside any window retires nothing");
    place(late, full);
    Check(retired(second) && !retired(late) && late.isAnimating,
          @"stale: the same view retires the older one once it lands in a window");

    [first startAnimation];
    Check(!retired(first) && !first.isHidden && first.isAnimating && draws(first) && retired(late),
          @"stale: restarting a retired view makes it the live one");

    [first removeFromSuperview];
    Check(retired(first) && !first.isAnimating && retired(late),
          @"stale: a view taken out of its window stops, and nothing resumes on its own");

    [first stopAnimation];
    Check(retired(first) && !first.isAnimating, @"stale: a second stopAnimation is harmless");
    for (ScreenSaverView *view in @[second, small, offscreen, late]) [view stopAnimation];
    for (NSWindow *window in windows) [window close];
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
        schemeResults = [NSMutableArray array];
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
                @[@"preview-fit", @800, @600, @YES]
            ];
            for (NSArray *entry in cases) {
                ScreenSaverView *view = NewView(NSMakeRect(0, 0, [entry[1] doubleValue], [entry[2] doubleValue]), [entry[3] boolValue]);
                NSArray *frames = [view valueForKey:@"frames"];
                Check(frames.count == 235, [NSString stringWithFormat:@"%@ loaded 235 frames", entry[0]]);
                if (frames.count != 235) continue;
                TestCycle(view, 1, entry[0], samples);
            }
            // One full cycle on a light-on-dark Catppuccin scheme: centering and
            // stability on the CGColor path with a non-black background.
            SelectScheme("catppuccin-mocha");
            ScreenSaverView *mochaView = NewView(NSMakeRect(0, 0, 1920, 1080), NO);
            if ([[mochaView valueForKey:@"frames"] count] == 235) TestCycle(mochaView, 1, @"landscape-mocha", samples);
            SelectScheme("classic");
            TestSchemeLookup();
            TestSchemeColors();
            TestOptionsSheet();
            TestSupersededViews();
            ScreenSaverView *view = NewView(NSMakeRect(0, 0, 1512, 982), NO);
            if ([[view valueForKey:@"frames"] count] == 235) {
                TestCycle(view, 2, @"retina", samples);
                NSBitmapImageRep *first = Render(view, 1, NULL, 1);
                NSBitmapImageRep *second = Render(view, 1, NULL, 1);
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
                Check(PixelDifference(Render(view, 1, NULL, 1), Render(fresh, 1, NULL, 1)) == 0,
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
            @"cycles": cycleResults, @"schemes": schemeResults,
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
