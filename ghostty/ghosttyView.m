//
//  ghosttyView.m
//  ghostty
//
//  Created by Wayne Wen on 1/11/25.
//

#import "ghosttyView.h"
#import "GhosttyFrameLoader.h"

@implementation ghosttyView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        GhosttyFrameLoader *loader = [[GhosttyFrameLoader alloc] init];
        NSBundle *thisBundle = [NSBundle bundleForClass:[self class]];
        self.frames = [loader loadFramesFromBundle:thisBundle];

        // Single reusable text layout stack. NSAttributedString's drawAtPoint:
        // creates and caches an internal layout manager PER string. Over hours
        // of screensaver runtime with 235 strings cycling, those internal caches
        // grow without bound. Using one explicit layout manager keeps cache size
        // bounded to the current frame only.
        self.textContainer = [[NSTextContainer alloc] initWithSize:NSMakeSize(1e7, 1e7)];
        self.textContainer.lineFragmentPadding = 0;
        self.layoutManager = [[NSLayoutManager alloc] init];
        [self.layoutManager addTextContainer:self.textContainer];
        self.textStorage = [[NSTextStorage alloc] init];
        [self.textStorage addLayoutManager:self.layoutManager];

        [self setAnimationTimeInterval:(1.0 / 30.0)];
        self.currentFrameIndex = 0;
        self.lastRenderedFrameIndex = -1;
    }
    return self;
}

#pragma mark - ScreenSaverView Lifecycle

- (void)startAnimation
{
    [super startAnimation];
}

- (void)stopAnimation
{
    [super stopAnimation];
    // Tear down layout stack so cached glyphs / layout data are freed
    [self.textStorage removeLayoutManager:self.layoutManager];
    self.textStorage = nil;
    self.layoutManager = nil;
    self.textContainer = nil;
    self.lastRenderedFrameIndex = -1;
}

// NSLayoutManager draws glyphs in a flipped coordinate system (origin at
// top-left, y increasing downward). ScreenSaverView inherits from NSView
// which is unflipped by default, causing the animation to render upside down.
- (BOOL)isFlipped
{
    return YES;
}

#pragma mark - Drawing & Animation

- (void)drawRect:(NSRect)rect
{
    @autoreleasepool {
        [[NSColor blackColor] setFill];
        NSRectFill(rect);

        if (self.frames.count == 0 || !self.layoutManager) {
            return;
        }

        // Swap the text storage content only when the frame actually changes.
        // setAttributedString: invalidates the old layout, so the layout
        // manager never accumulates stale cache entries across frames.
        if (self.lastRenderedFrameIndex != self.currentFrameIndex) {
            [self.textStorage setAttributedString:self.frames[self.currentFrameIndex]];
            self.lastRenderedFrameIndex = self.currentFrameIndex;
        }

        // Measure and center using the layout manager (not [attrStr size],
        // which would trigger a separate internal layout cache).
        NSRange glyphRange = [self.layoutManager glyphRangeForTextContainer:self.textContainer];
        NSRect usedRect = [self.layoutManager usedRectForTextContainer:self.textContainer];

        CGFloat x = NSMidX(self.bounds) - (usedRect.size.width  / 2.0);
        CGFloat y = NSMidY(self.bounds) - (usedRect.size.height / 2.0);

        [self.layoutManager drawGlyphsForGlyphRange:glyphRange atPoint:NSMakePoint(x, y)];
    }
}

- (void)animateOneFrame
{
    if (self.frames.count > 0) {
        self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count;
    }
    [self setNeedsDisplay:YES];
}

- (BOOL)hasConfigureSheet
{
    return NO;
}

- (NSWindow *)configureSheet
{
    return nil;
}

@end
