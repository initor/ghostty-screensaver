//
//  GhosttyOptionsSheet.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 9/19/26.
//

#import "GhosttyOptionsSheet.h"
#import "GhosttyColorScheme.h"

@interface GhosttyOptionsSheet ()
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSPopUpButton *popup;
// What the views drew when the sheet opened. Cancel restores it.
@property (nonatomic, strong) GhosttyColorScheme *schemeAtOpen;
@end

@implementation GhosttyOptionsSheet

- (instancetype)init
{
    self = [super init];
    if (self) {
        [self buildWindow];
    }
    return self;
}

- (void)buildWindow
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 380, 120)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    // The default is YES. The host does not retain the sheet and we reuse
    // it, so a -close from anywhere would leave a dangling pointer.
    window.releasedWhenClosed = NO;
    window.title = @"Ghostty Screensaver";

    NSTextField *label = [NSTextField labelWithString:@"Color scheme:"];

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (GhosttyColorScheme *scheme in GhosttyColorScheme.allSchemes) {
        [popup addItemWithTitle:scheme.displayName];
    }
    popup.target = self;
    popup.action = @selector(popupDidChange:);

    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancel:)];
    cancel.keyEquivalent = @"\033";
    NSButton *ok = [NSButton buttonWithTitle:@"OK" target:self action:@selector(save:)];
    ok.keyEquivalent = @"\r";

    NSStackView *row = [NSStackView stackViewWithViews:@[label, popup]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[cancel, ok]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    NSStackView *column = [NSStackView stackViewWithViews:@[row, buttons]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeTrailing;
    column.spacing = 16;
    column.edgeInsets = NSEdgeInsetsMake(20, 20, 20, 20);
    column.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *content = window.contentView;
    [content addSubview:column];
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [column.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [column.topAnchor constraintEqualToAnchor:content.topAnchor],
        [column.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];

    self.window = window;
    self.popup = popup;
}

#pragma mark - Public

- (void)prepareWithScheme:(GhosttyColorScheme *)scheme
{
    self.schemeAtOpen = scheme;
    NSUInteger index = [GhosttyColorScheme.allSchemes indexOfObject:scheme];
    [self.popup selectItemAtIndex:(index == NSNotFound) ? 0 : (NSInteger)index];
}

#pragma mark - Actions

- (GhosttyColorScheme *)selectedScheme
{
    NSArray<GhosttyColorScheme *> *all = GhosttyColorScheme.allSchemes;
    NSInteger index = self.popup.indexOfSelectedItem;
    if (index >= 0 && (NSUInteger)index < all.count) {
        return all[(NSUInteger)index];
    }
    return all.firstObject;
}

- (void)popupDidChange:(id)sender
{
    [self broadcast:[self selectedScheme]];
}

- (void)save:(id)sender
{
    GhosttyColorScheme *scheme = [self selectedScheme];
    [GhosttyColorScheme storeScheme:scheme];
    [self broadcast:scheme];
    [self dismiss];
}

- (void)cancel:(id)sender
{
    [self broadcast:self.schemeAtOpen];
    [self dismiss];
}

- (void)broadcast:(GhosttyColorScheme *)scheme
{
    [NSNotificationCenter.defaultCenter postNotificationName:GhosttyColorSchemeDidChangeNotification
                                                      object:self
                                                    userInfo:@{ GhosttyColorSchemeIdentifierKey: scheme.identifier }];
}

- (void)dismiss
{
    // The documented contract: the saver ends the sheet itself. orderOut: is
    // the fallback for a host that showed the window some other way.
    NSWindow *parent = self.window.sheetParent;
    if (parent) {
        [parent endSheet:self.window];
    } else {
        [self.window orderOut:nil];
    }
}

@end
