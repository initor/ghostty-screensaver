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

// Reusable text layout stack — avoids per-string layout cache accumulation
@property (nonatomic, strong) NSTextStorage *textStorage;
@property (nonatomic, strong) NSLayoutManager *layoutManager;
@property (nonatomic, strong) NSTextContainer *textContainer;
@property (nonatomic, assign) NSInteger lastRenderedFrameIndex;

@end
