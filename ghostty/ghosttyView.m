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
        
        // pre-compute frame into images
        self.frameImages = [loader buildFrameImagesFromAttributedStrings:self.frames];
        
        // initial values
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

    if (self.frameImages.count == 0) {
        NSLog(@"[ghostty] no frame images to draw");
        return;
    }

    NSImage *currentImage = self.frameImages[self.currentFrameIndex];
    NSSize imageSize = currentImage.size;
    CGFloat x = NSMidX(self.bounds) - (imageSize.width  / 2.0);
    CGFloat y = NSMidY(self.bounds) - (imageSize.height / 2.0);
    
    // draw
    [currentImage drawAtPoint:NSMakePoint(x, y) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
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
