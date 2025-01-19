//
//  GhosttyPerformanceTests.m
//  GhosttyPerformanceTests
//
//  Created by Wayne Wen on 1/18/25.
//

#import <XCTest/XCTest.h>
#import "GhosttyFrameLoader.h"

@interface GhosttyPerformanceTests : XCTestCase
@property (nonatomic, strong) GhosttyFrameLoader *loader;
@property (nonatomic, strong) NSArray<NSAttributedString *> *frames;
@end

@implementation GhosttyPerformanceTests

- (void)setUp {
    [super setUp];
    
    // We'll create a ghosttyView with a typical screen size for testing.
    // Start with a 3456x2234 display.
    self.loader = [[GhosttyFrameLoader alloc] init];
    NSBundle *testBundle = [NSBundle bundleForClass:[self class]];
    self.frames = [self.loader loadFramesFromBundle:testBundle];
}

- (void)testBuildFrameImagesPerformance {
    [self measureBlock:^{
        NSArray<NSImage *> *images =
            [self.loader buildFrameImagesFromAttributedStrings:self.frames];
        XCTAssertNotNil(images);
        XCTAssertEqual(images.count, self.frames.count);
    }];
}

/* Test boilerplate
- (void)tearDown {
    // Put teardown code here. This method is called after the invocation of each test method in the class.
}

- (void)testExample {
    // This is an example of a functional test case.
    // Use XCTAssert and related functions to verify your tests produce the correct results.
}

- (void)testPerformanceExample {
    // This is an example of a performance test case.
    [self measureBlock:^{
        // Put the code you want to measure the time of here.
    }];
}
*/
@end
