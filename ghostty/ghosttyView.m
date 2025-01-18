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
        
        // precompute sizes
        NSMutableArray<NSValue *> *sizes = [NSMutableArray arrayWithCapacity:self.frames.count];
        for (NSAttributedString *as in self.frames) {
            [sizes addObject:[NSValue valueWithSize:[as size]]];
        }
        self.frameSizes = [sizes copy];
        
        [self setAnimationTimeInterval:(1.0 / 30.0)];
        self.currentFrameIndex = 0;
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
}

#pragma mark - Drawing & Animation

- (void)drawRect:(NSRect)rect
{
    [[NSColor blackColor] setFill];
    NSRectFill(rect);

    if (self.frames.count == 0) {
        NSLog(@"[ghostty] no frames to draw");
        return;
    }

    NSAttributedString *currentFrame = self.frames[self.currentFrameIndex];

    // measure and center
    NSSize textSize = [self.frameSizes[self.currentFrameIndex] sizeValue];
    CGFloat x = NSMidX(self.bounds) - (textSize.width  / 2.0);
    CGFloat y = NSMidY(self.bounds) - (textSize.height / 2.0);

    // draw
    [currentFrame drawAtPoint:NSMakePoint(x, y)];
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
