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

@end
