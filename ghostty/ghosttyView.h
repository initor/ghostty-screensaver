//
//  ghosttyView.h
//  ghostty
//
//  Created by Wayne Wen on 1/11/25.
//

#import <ScreenSaver/ScreenSaver.h>

@interface ghosttyView : ScreenSaverView

@property (nonatomic, strong) NSArray<NSAttributedString *> *frames;
@property (nonatomic, assign) NSInteger currentFrameIndex;

/**
 An array of images, each rendered from the corresponding NSAttributedString.
 Draw from this array at runtime for maximum performance.
*/
@property (nonatomic, strong) NSArray<NSImage *> *frameImages;

@end
