//
//  GhosttyView.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/11/25.
//

#import "GhosttyView.h"
#import "GhosttyColorScheme.h"
#import "GhosttyFrameLoader.h"
#import "GhosttyOptionsSheet.h"
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <os/signpost.h>

// Full-rate vs Low Power Mode rates. The screensaver is a textbook
// discretionary workload, so M11 throttles to half-rate on battery + LPM.
static const NSTimeInterval kGhosttyFrameIntervalNormal = 1.0 / 30.0;
static const NSTimeInterval kGhosttyFrameIntervalLowPower = 1.0 / 15.0;
// Fraction of the shorter bounds side kept clear when the canvas has to
// shrink to fit (the System Settings preview). The ink spans 39 of the 41
// rows, so an exact fit would put the halo on the edge. Applies only when
// the canvas does not fit: a display that fits it keeps today's placement.
static const CGFloat kGhosttyFitMargin = 0.08;
static os_log_t sLog;
// Always-on signpost log on the Points-of-Interest category. Auto-discovered
// by Instruments and zero-cost when no client is attached.
static os_log_t sPOILog;

@interface GhosttyView ()

// The active scheme and its frames. Frames are process-shared and immutable;
// multi-display and preview-pane instances on the same scheme reuse one
// array. tests/render_bundle.m reads `frames` by name via valueForKey:.
@property (nonatomic, strong) GhosttyColorScheme *scheme;
@property (nonatomic, copy) NSArray<NSAttributedString *> *frames;

// Cycled by animateOneFrame each tick.
@property (nonatomic, assign) NSInteger currentFrameIndex;

// Cached placement, keyed on bounds only. Every frame shares one canvas
// size, so the origin and fit depend on nothing else. The harness reads
// cachedDrawSize, cachedDrawOrigin and cachedFit by name.
@property (nonatomic, assign) CGSize cachedDrawSize;
@property (nonatomic, assign) CGPoint cachedDrawOrigin;
@property (nonatomic, assign) CGFloat cachedFit;
@property (nonatomic, assign) CGRect cachedBounds;

// The host does not retain the sheet; this reference keeps it alive.
@property (nonatomic, strong) GhosttyOptionsSheet *optionsSheet;

@end

@implementation GhosttyView

+ (void)initialize
{
    if (self == [GhosttyView class]) {
        sLog = os_log_create("com.initor.ghostty-screensaver", "View");
        sPOILog = os_log_create("com.initor.ghostty-screensaver", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
    }
}

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // Layer-backed: WindowServer composites the backing store on the
        // GPU and the layer's backgroundColor handles the per-tick fill
        // that the original NSRectFill used to do on the CPU.
        self.wantsLayer = YES;

        // Read once. Both supported hosts create a fresh view per
        // activation (macOS 26 reuses the process, macOS 27 does not), so
        // init is where the stored value is fresh. The Options sheet is the
        // only other writer and it broadcasts its changes.
        [self applyScheme:[GhosttyColorScheme storedScheme]];

        [self applyAnimationRateForCurrentPowerState];
        self.currentFrameIndex = 0;
        self.cachedBounds = CGRectNull;

        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        // M11 — Track Low Power Mode and re-apply the rate on changes.
        // The notification fires on the user toggling LPM from the menu
        // bar / Settings, or on automatic enter/exit by the OS.
        [center addObserver:self
                   selector:@selector(ghosttyPowerStateDidChange:)
                       name:NSProcessInfoPowerStateDidChangeNotification
                     object:nil];
        [center addObserver:self
                   selector:@selector(ghosttyColorSchemeDidChange:)
                       name:GhosttyColorSchemeDidChangeNotification
                     object:nil];

        os_log_info(sLog,
                    "Init view (preview=%{public}d, %.0fx%.0f, frames=%{public}lu, scheme=%{public}@, lpm=%{public}d)",
                    isPreview, frame.size.width, frame.size.height,
                    (unsigned long)self.frames.count,
                    self.scheme.identifier,
                    (int)NSProcessInfo.processInfo.lowPowerModeEnabled);
    }
    return self;
}

- (void)dealloc
{
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center removeObserver:self name:NSProcessInfoPowerStateDidChangeNotification object:nil];
    [center removeObserver:self name:GhosttyColorSchemeDidChangeNotification object:nil];
}

#pragma mark - Color scheme

- (void)applyScheme:(GhosttyColorScheme *)scheme
{
    if (scheme == self.scheme && self.frames.count > 0) {
        return;
    }
    NSBundle *thisBundle = [NSBundle bundleForClass:[self class]];
    self.frames = [GhosttyFrameLoader framesForScheme:scheme bundle:thisBundle];
    self.scheme = scheme;
    // The loader fails open on a bad frame file, so a new load can be
    // shorter than the array this view was cycling. Keep the index in range
    // for the draw that setNeedsDisplay: triggers.
    if (self.currentFrameIndex >= (NSInteger)self.frames.count) {
        self.currentFrameIndex = 0;
    }
    self.layer.backgroundColor = scheme.backgroundColor;
    [self setNeedsDisplay:YES];
}

- (void)ghosttyColorSchemeDidChange:(NSNotification *)note
{
    NSString *identifier = note.userInfo[GhosttyColorSchemeIdentifierKey];
    [self applyScheme:[GhosttyColorScheme schemeWithIdentifier:identifier]];
}

#pragma mark - Options sheet

- (BOOL)hasConfigureSheet
{
    return YES;
}

- (NSWindow *)configureSheet
{
    if (!self.optionsSheet) {
        self.optionsSheet = [[GhosttyOptionsSheet alloc] init];
    }
    [self.optionsSheet prepareWithScheme:self.scheme];
    return self.optionsSheet.window;
}

#pragma mark - Power state

- (void)applyAnimationRateForCurrentPowerState
{
    BOOL lpm = NSProcessInfo.processInfo.lowPowerModeEnabled;
    self.animationTimeInterval = lpm
        ? kGhosttyFrameIntervalLowPower
        : kGhosttyFrameIntervalNormal;
}

- (void)ghosttyPowerStateDidChange:(NSNotification *)note
{
    // Posted on a global dispatch queue. animationTimeInterval reschedules
    // the host's NSTimer, which belongs to the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL lpm = NSProcessInfo.processInfo.lowPowerModeEnabled;
        os_log_info(sLog, "Power state change → lpm=%{public}d (%.1f Hz)",
                    (int)lpm, lpm ? 15.0 : 30.0);
        [self applyAnimationRateForCurrentPowerState];
    });
}

#pragma mark - ScreenSaverView Lifecycle

// startAnimation / stopAnimation use ScreenSaverView's defaults. The view
// is layer-backed and Core Text-driven, so there is no per-instance
// layout-manager state to tear down between activations — the original
// teardown in -stopAnimation was the source of the H1 stop→start dead-
// view bug when the host re-activated the same instance after a sleep.

#pragma mark - Drawing & Animation

- (void)drawRect:(NSRect)rect
{
    os_signpost_id_t spid = os_signpost_id_generate(sPOILog);
    os_signpost_interval_begin(sPOILog, spid, "DrawFrame",
                               "frame=%{public}ld",
                               (long)self.currentFrameIndex);

    CGRect bounds = self.bounds;
    CGSize canvas = [GhosttyFrameLoader canvasSize];
    // Empty bounds cover the 0×0 preview instance macOS 26 creates; an
    // empty canvas means no frames loaded.
    if (self.frames.count == 0 || NSIsEmptyRect(bounds) ||
        canvas.width <= 0 || canvas.height <= 0) {
        os_signpost_interval_end(sPOILog, spid, "DrawFrame", "empty");
        return;
    }

    NSAttributedString *attr = self.frames[(NSUInteger)self.currentFrameIndex];
    CFAttributedStringRef cfAttr = (__bridge CFAttributedStringRef)attr;
    CFRange textRange = CFRangeMake(0, (CFIndex)attr.length);

    // Placement is a function of bounds alone: the canvas size is shared by
    // every frame and the ink midpoint is one anchor for the whole loop.
    // Recompute only when the host changes bounds (it can do so without
    // calling setFrame:), never per tick.
    if (!CGRectEqualToRect(self.cachedBounds, bounds)) {
        // The canvas never shrinks while it fits, so every display that
        // shows the whole ghost today is unchanged. When it does not fit
        // (the System Settings preview), shrink it inside a margin.
        CGFloat fit = 1.0;
        if (MIN(bounds.size.width / canvas.width, bounds.size.height / canvas.height) < 1.0) {
            CGFloat margin = kGhosttyFitMargin * MIN(bounds.size.width, bounds.size.height);
            fit = MIN((bounds.size.width - 2.0 * margin) / canvas.width,
                      (bounds.size.height - 2.0 * margin) / canvas.height);
            fit = MIN(1.0, MAX(fit, 0.01));
        }
        self.cachedFit = fit;
        self.cachedDrawSize = canvas;
        self.cachedDrawOrigin = CGPointMake(NSMidX(bounds) - canvas.width / 2.0,
                                            NSMidY(bounds) - [GhosttyFrameLoader inkMidpoint]);
        self.cachedBounds = bounds;
    }

    CGRect pathRect = CGRectMake(self.cachedDrawOrigin.x, self.cachedDrawOrigin.y,
                                 self.cachedDrawSize.width, self.cachedDrawSize.height);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, pathRect);
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(cfAttr);
    CTFrameRef ctFrame = CTFramesetterCreateFrame(framesetter, textRange, path, NULL);
    CGPathRelease(path);

    // Core Text draws in CG (unflipped) coordinates natively. NSView is
    // unflipped by default and the screensaver compositing layer respects
    // that, so no CTM flip is required (unlike the previous NSLayoutManager
    // path, which rendered top-left and required an explicit
    // CGContextScaleCTM(1, -1) workaround per commits 2365964/06172be).
    //
    // CTFrameRef and CTFramesetterRef are short-lived per tick — they are
    // not retained between draws, which is the H6 fix: NSLayoutManager's
    // glyph/font caches grew unboundedly across setAttributedString: swaps
    // (~1.6 KB / frame, no plateau on macOS 26 per B8 measurement).
    // Retaining 235 CTFrames instead would cost 45 MB for 0.12 ms per tick.
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(ctx);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    if (self.cachedFit < 1.0) {
        // Shrink about the bounds center. The origin already centers the
        // canvas horizontally and the ink midpoint vertically on that
        // point, so scaling about it keeps both centered.
        CGContextTranslateCTM(ctx, NSMidX(bounds), NSMidY(bounds));
        CGContextScaleCTM(ctx, self.cachedFit, self.cachedFit);
        CGContextTranslateCTM(ctx, -NSMidX(bounds), -NSMidY(bounds));
    }
    CTFrameDraw(ctFrame, ctx);
    CGContextRestoreGState(ctx);

    CFRelease(ctFrame);
    CFRelease(framesetter);

    os_signpost_interval_end(sPOILog, spid, "DrawFrame");
}

- (void)animateOneFrame
{
    if (self.frames.count == 0) {
        return;
    }
    self.currentFrameIndex = (self.currentFrameIndex + 1) % (NSInteger)self.frames.count;
    os_signpost_event_emit(sPOILog, OS_SIGNPOST_ID_EXCLUSIVE, "Tick",
                           "frame=%{public}ld",
                           (long)self.currentFrameIndex);
    [self setNeedsDisplay:YES];
}

@end
