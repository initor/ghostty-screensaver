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

static const NSTimeInterval kGhosttyFrameInterval = 1.0 / 30.0;
static os_log_t sLog;

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

        self.animationTimeInterval = kGhosttyFrameInterval;
        self.currentFrameIndex = 0;
        self.cachedOriginIndex = -1;
        self.cachedBoundsSize = frame.size;

        os_log_info(sLog,
                    "Init view (preview=%{public}d, %.0fx%.0f, frames=%{public}lu)",
                    isPreview, frame.size.width, frame.size.height,
                    (unsigned long)self.frames.count);
    }
    return self;
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
    if (self.frames.count == 0) {
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
}

- (void)animateOneFrame
{
    if (self.frames.count == 0) {
        return;
    }
    self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count;
    [self setNeedsDisplay:YES];
}

@end
