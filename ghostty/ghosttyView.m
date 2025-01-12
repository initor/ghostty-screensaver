//
//  ghosttyView.m
//  ghostty
//
//  Created by Wayne Wen on 1/11/25.
//

#import "ghosttyView.h"

@implementation ghosttyView

#pragma mark - Initialization

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        [self concurrentLoadAllFrames];
        [self setAnimationTimeInterval:(1.0 / 30.0)];
        self.currentFrameIndex = 0;
    }
    return self;
}

#pragma mark - Frame Loading

- (void)loadAllFrames
{
    NSLog(@"[ghostty] loadAllFrames: scanning .txt resources");
    
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];
    paths = [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    NSMutableArray<NSAttributedString *> *loadedFrames = [NSMutableArray array];

    for (NSString *path in paths) {
        NSError *error = nil;
        NSString *rawContent = [NSString stringWithContentsOfFile:path
                                                         encoding:NSUTF8StringEncoding
                                                            error:&error];
        if (!rawContent || error) {
            NSLog(@"[ghostty] could not read %@ (error=%@)", path, error);
            continue;
        }

        // parse <span class="b"> blocks as blue; everything else is white
        NSAttributedString *frameString = [self attributedFrameFromRawHTML:rawContent];
        [loadedFrames addObject:frameString];

        NSLog(@"[ghostty] loaded frame from %@", path);
    }

    self.frames = [loadedFrames copy];
    NSLog(@"[ghostty] loadAllFrames: total frames = %lu", (unsigned long)self.frames.count);
}

#pragma mark - Frame Concurrent Loading

- (void)concurrentLoadAllFrames
{
    NSLog(@"[ghostty] concurrentLoadAllFrames: scanning .txt resources");
    
    // find all .txt files in this screensaver’s bundle
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    NSArray<NSString *> *paths = [bundle pathsForResourcesOfType:@"txt" inDirectory:nil];
    
    // sort them so frame_001.txt, frame_002.txt, etc., remain in order
    paths = [paths sortedArrayUsingSelector:@selector(localizedStandardCompare:)];

    // create a dispatch group + concurrent queue
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);

    // dictionary to hold parsed frames keyed by their index
    NSMutableDictionary<NSNumber *, NSAttributedString *> *results =
        [NSMutableDictionary dictionary];

    // enumerate files and parse them in parallel
    [paths enumerateObjectsUsingBlock:^(NSString *path, NSUInteger idx, BOOL *stop) {
        dispatch_group_async(group, queue, ^{
            NSError *error = nil;
            NSString *rawContent = [NSString stringWithContentsOfFile:path
                                                             encoding:NSUTF8StringEncoding
                                                                error:&error];
            if (!rawContent || error) {
                NSLog(@"[ghostty] could not read %@ (error=%@)", path, error);
                return;
            }

            // convert spans to colored text
            NSAttributedString *frameString =
                [self attributedFrameFromRawHTML:rawContent];

            // store the result in a thread-safe way
            @synchronized (results) {
                results[@(idx)] = frameString;
            }

            NSLog(@"[ghostty] loaded frame from %@", path);
        });
    }];

    // wait for all parse tasks to finish
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    // build a final NSMutableArray in sorted order
    NSMutableArray<NSAttributedString *> *finalFrames =
        [NSMutableArray arrayWithCapacity:paths.count];

    for (NSUInteger i = 0; i < paths.count; i++) {
        NSAttributedString *frame = nil;
        @synchronized (results) {
            frame = results[@(i)];
        }
        // if something failed or is missing, use an empty fallback
        if (!frame) {
            frame = [[NSAttributedString alloc] initWithString:@""];
        }
        [finalFrames addObject:frame];
    }

    // assign to self.frames
    self.frames = [finalFrames copy];
    NSLog(@"[ghostty] concurrentLoadAllFrames: total frames = %lu",
          (unsigned long)self.frames.count);
}



#pragma mark - Parsing

// parses <span class="b">…</span> blocks as blue text and leaves other text in white
- (NSAttributedString *)attributedFrameFromRawHTML:(NSString *)raw
{
    NSColor *blueColor  = [NSColor colorWithSRGBRed:0.0
                                             green:0.0
                                              blue:(230.0 / 255.0)
                                             alpha:1.0];
    NSColor *whiteColor = [NSColor colorWithSRGBRed:(215.0 / 255.0)
                                             green:(215.0 / 255.0)
                                              blue:(215.0 / 255.0)
                                             alpha:1.0];

    NSFont *monospacedFont = [NSFont fontWithName:@"Menlo" size:16.0];

    NSDictionary *attrsWhite = @{
        NSFontAttributeName: monospacedFont,
        NSForegroundColorAttributeName: whiteColor
    };
    NSDictionary *attrsBlue = @{
        NSFontAttributeName: monospacedFont,
        NSForegroundColorAttributeName: blueColor
    };

    NSString *pattern = @"<span class=\"b\">(.*?)</span>";
    NSRegularExpressionOptions options = NSRegularExpressionDotMatchesLineSeparators;
    NSError *regexError = nil;
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:pattern
                                                  options:options
                                                    error:&regexError];
    if (!regex) {
        NSLog(@"[ghostty] regex error: %@", regexError);
        return [[NSAttributedString alloc] initWithString:raw attributes:attrsWhite];
    }

    NSMutableAttributedString *parsed = [[NSMutableAttributedString alloc] init];
    NSUInteger lastLoc = 0;
    NSArray<NSTextCheckingResult *> *matches =
        [regex matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];

    for (NSTextCheckingResult *match in matches) {
        NSRange fullMatchRange = [match rangeAtIndex:0]; // entire <span...>...</span>
        NSRange innerRange     = [match rangeAtIndex:1]; // text inside the tags

        // add outside text as white
        if (fullMatchRange.location > lastLoc) {
            NSRange outsideRange = NSMakeRange(lastLoc, fullMatchRange.location - lastLoc);
            NSString *outsideText = [raw substringWithRange:outsideRange];
            NSAttributedString *outsideAS =
                [[NSAttributedString alloc] initWithString:outsideText
                                                attributes:attrsWhite];
            [parsed appendAttributedString:outsideAS];
        }

        // add inner text as blue
        NSString *blueText = [raw substringWithRange:innerRange];
        NSAttributedString *blueAS =
            [[NSAttributedString alloc] initWithString:blueText attributes:attrsBlue];
        [parsed appendAttributedString:blueAS];

        lastLoc = fullMatchRange.location + fullMatchRange.length;
    }

    // add trailing text as white
    if (lastLoc < raw.length) {
        NSRange trailingRange = NSMakeRange(lastLoc, raw.length - lastLoc);
        NSString *trailingText = [raw substringWithRange:trailingRange];
        NSAttributedString *trailingAS =
            [[NSAttributedString alloc] initWithString:trailingText attributes:attrsWhite];
        [parsed appendAttributedString:trailingAS];
    }

    return [parsed copy];
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
    NSSize textSize = [currentFrame size];
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
