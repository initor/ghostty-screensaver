//
//  ghosttyView.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 1/11/25.
//

#import "ghosttyView.h"
#import "GhosttyFrameLoader.h"
#import <CoreText/CoreText.h>
#import <os/log.h>
#import <os/signpost.h>

// Full-rate vs Low Power Mode rates. The screensaver is a textbook
// discretionary workload, so M11 throttles to half-rate on battery + LPM.
static const NSTimeInterval kGhosttyFrameIntervalNormal = 1.0 / 30.0;
static const NSTimeInterval kGhosttyFrameIntervalLowPower = 1.0 / 15.0;
static os_log_t sLog;
// Always-on signpost log on the Points-of-Interest category. Auto-discovered
// by Instruments and zero-cost when no client is attached.
static os_log_t sPOILog;

@interface ghosttyView ()

// Process-shared, immutable. Acquired in init via
// +[GhosttyFrameLoader sharedFramesForBundle:]; multi-display and
// preview-pane instances reuse the same array.
@property (nonatomic, copy) NSArray<NSAttributedString *> *frames;

// Cycled by animateOneFrame each tick.
@property (nonatomic, assign) NSInteger currentFrameIndex;

// Cached centering math. The used-rect produced by Core Text and the
// resulting centered origin are a function of (frame-index, view-bounds);
// recomputing every tick is wasted work.
@property (nonatomic, assign) NSInteger cachedOriginIndex;
@property (nonatomic, assign) CGSize cachedDrawSize;
@property (nonatomic, assign) CGPoint cachedDrawOrigin;
@property (nonatomic, assign) CGSize cachedBoundsSize;

@end

@implementation ghosttyView

+ (void)initialize
{
    if (self == [ghosttyView class]) {
        sLog = os_log_create("com.ghostty.screensaver", "View");
        sPOILog = os_log_create("com.ghostty.screensaver", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
    }
}

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        // Layer-backed: WindowServer composites the backing store on the
        // GPU and the layer's backgroundColor handles the per-tick black
        // fill that the original NSRectFill used to do on the CPU.
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;

        // Process-singleton frame array. The first ghosttyView pays the
        // ~30 ms (warm) load cost; every subsequent instance — multi-
        // display, System Settings preview pane, view re-instantiation —
        // returns instantly with the same immutable array.
        NSBundle *thisBundle = [NSBundle bundleForClass:[self class]];
        self.frames = [GhosttyFrameLoader sharedFramesForBundle:thisBundle];

        [self applyAnimationRateForCurrentPowerState];
        self.currentFrameIndex = 0;
        self.cachedOriginIndex = -1;
        self.cachedBoundsSize = frame.size;

        // M11 — Track Low Power Mode and re-apply the rate on changes.
        // The notification fires on the user toggling LPM from the menu
        // bar / Settings, or on automatic enter/exit by the OS.
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(ghosttyPowerStateDidChange:)
                                                     name:NSProcessInfoPowerStateDidChangeNotification
                                                   object:nil];

        os_log_info(sLog,
                    "Init view (preview=%{public}d, %.0fx%.0f, frames=%{public}lu, lpm=%{public}d)",
                    isPreview, frame.size.width, frame.size.height,
                    (unsigned long)self.frames.count,
                    (int)NSProcessInfo.processInfo.lowPowerModeEnabled);
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSProcessInfoPowerStateDidChangeNotification
                                                  object:nil];
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
    BOOL lpm = NSProcessInfo.processInfo.lowPowerModeEnabled;
    os_log_info(sLog, "Power state change → lpm=%{public}d (%.1f Hz)",
                (int)lpm, lpm ? 15.0 : 30.0);
    [self applyAnimationRateForCurrentPowerState];
}

#pragma mark - Bounds Tracking

- (void)setFrame:(NSRect)frame
{
    [super setFrame:frame];
    if (!CGSizeEqualToSize(self.cachedBoundsSize, frame.size)) {
        self.cachedOriginIndex = -1;  // origin depends on bounds
        self.cachedBoundsSize = frame.size;
    }
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

    if (self.frames.count == 0) {
        os_signpost_interval_end(sPOILog, spid, "DrawFrame", "empty");
        return;
    }

    NSAttributedString *attr = self.frames[self.currentFrameIndex];
    CFAttributedStringRef cfAttr = (__bridge CFAttributedStringRef)attr;
    CFRange textRange = CFRangeMake(0, (CFIndex)attr.length);

    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(cfAttr);

    // Used-rect and centered origin are stable for a given (index, bounds)
    // pair. Cache so steady-state animation only recomputes when the index
    // advances (every tick by definition) but not when drawRect: is called
    // for non-animation reasons (resize, occlusion change). Bounds changes
    // invalidate via -setFrame: above.
    CGSize usedSize;
    CGPoint origin;
    if (self.cachedOriginIndex == self.currentFrameIndex) {
        usedSize = self.cachedDrawSize;
        origin = self.cachedDrawOrigin;
    } else {
        usedSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            textRange,
            NULL,
            CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX),
            NULL);
        origin = CGPointMake(NSMidX(self.bounds) - usedSize.width  / 2.0,
                             NSMidY(self.bounds) - usedSize.height / 2.0);
        self.cachedDrawSize    = usedSize;
        self.cachedDrawOrigin  = origin;
        self.cachedOriginIndex = self.currentFrameIndex;
    }

    CGRect pathRect = CGRectMake(origin.x, origin.y, usedSize.width, usedSize.height);
    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, pathRect);
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
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    CTFrameDraw(ctFrame, ctx);

    CFRelease(ctFrame);
    CFRelease(framesetter);

    os_signpost_interval_end(sPOILog, spid, "DrawFrame");
}

- (void)animateOneFrame
{
    if (self.frames.count == 0) {
        return;
    }
    self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count;
    os_signpost_event_emit(sPOILog, OS_SIGNPOST_ID_EXCLUSIVE, "Tick",
                           "frame=%{public}ld",
                           (long)self.currentFrameIndex);
    [self setNeedsDisplay:YES];
}

@end
