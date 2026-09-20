//
//  GhosttyColorScheme.m
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 9/19/26.
//

#import "GhosttyColorScheme.h"
#import <ScreenSaver/ScreenSaver.h>
#import <os/log.h>

NSNotificationName const GhosttyColorSchemeDidChangeNotification = @"GhosttyColorSchemeDidChangeNotification";
NSString * const GhosttyColorSchemeIdentifierKey = @"identifier";

// The preference contract. The module name is the bundle identifier, so the
// value lands in the saver's own ByHost plist inside the legacyScreenSaver
// sandbox container. Changing either string orphans every stored choice.
static NSString * const kGhosttyModuleName   = @"com.initor.ghostty-screensaver";
static NSString * const kGhosttyPreferenceKey = @"ColorScheme";

typedef struct {
    const char *identifier;    // stored value, lowercase ASCII
    const char *displayName;   // popup title, UTF-8
    uint32_t background;       // 0xRRGGBB, sRGB
    uint32_t body;
    uint32_t accent;
} GhosttyColorSchemeSpec;

// Table order is popup order. Row 0 is the fallback and draws exactly what
// every version before 1.8.0 drew. The Catppuccin rows map base / text /
// blue from palette 1.8.0 (MIT, Copyright (c) 2021 Catppuccin).
static const GhosttyColorSchemeSpec kGhosttySchemes[] = {
    { "classic",              "Classic",              0x000000, 0xd7d7d7, 0x0000e6 },
    { "catppuccin-latte",     "Catppuccin Latte",     0xeff1f5, 0x4c4f69, 0x1e66f5 },
    { "catppuccin-frappe",    "Catppuccin Frappé",    0x303446, 0xc6d0f5, 0x8caaee },
    { "catppuccin-macchiato", "Catppuccin Macchiato", 0x24273a, 0xcad3f5, 0x8aadf4 },
    { "catppuccin-mocha",     "Catppuccin Mocha",     0x1e1e2e, 0xcdd6f4, 0x89b4fa },
};
static const size_t kGhosttySchemeCount = sizeof(kGhosttySchemes) / sizeof(kGhosttySchemes[0]);

static os_log_t sLog;

static CGColorRef GhosttyCreateSRGBColor(uint32_t rgb)
{
    return CGColorCreateSRGB(((rgb >> 16) & 0xff) / 255.0,
                             ((rgb >> 8) & 0xff) / 255.0,
                             (rgb & 0xff) / 255.0,
                             1.0);
}

@interface GhosttyColorScheme ()
- (instancetype)initWithSpec:(const GhosttyColorSchemeSpec *)spec;
@end

@implementation GhosttyColorScheme

+ (void)initialize
{
    if (self == [GhosttyColorScheme class]) {
        sLog = os_log_create("com.initor.ghostty-screensaver", "ColorScheme");
    }
}

- (instancetype)initWithSpec:(const GhosttyColorSchemeSpec *)spec
{
    self = [super init];
    if (self) {
        _identifier = @(spec->identifier);
        _displayName = @(spec->displayName);
        // CGColor, not NSColor: the frames carry these under
        // kCTForegroundColorAttributeName, so CTFrameDraw uses them directly
        // instead of converting an NSColor through ColorSync on every run.
        _backgroundColor = GhosttyCreateSRGBColor(spec->background);
        _bodyColor = GhosttyCreateSRGBColor(spec->body);
        _accentColor = GhosttyCreateSRGBColor(spec->accent);
    }
    return self;
}

- (void)dealloc
{
    // The table instances live for the process; this keeps ownership honest.
    CGColorRelease(_backgroundColor);
    CGColorRelease(_bodyColor);
    CGColorRelease(_accentColor);
}

#pragma mark - Table

+ (NSArray<GhosttyColorScheme *> *)allSchemes
{
    static NSArray<GhosttyColorScheme *> *schemes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<GhosttyColorScheme *> *built = [NSMutableArray arrayWithCapacity:kGhosttySchemeCount];
        for (size_t i = 0; i < kGhosttySchemeCount; i++) {
            [built addObject:[[GhosttyColorScheme alloc] initWithSpec:&kGhosttySchemes[i]]];
        }
        schemes = [built copy];
    });
    return schemes;
}

+ (GhosttyColorScheme *)schemeWithIdentifier:(NSString *)identifier
{
    NSString *wanted = [[identifier stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                        lowercaseString];
    for (GhosttyColorScheme *scheme in [self allSchemes]) {
        if ([scheme.identifier isEqualToString:wanted]) {
            return scheme;
        }
    }
    return [self allSchemes].firstObject;
}

#pragma mark - Preference

+ (GhosttyColorScheme *)storedScheme
{
    // A fresh instance per read. It costs one plist read per view creation
    // and sidesteps whatever ScreenSaverDefaults caches in memory.
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:kGhosttyModuleName];
    NSString *stored = [defaults stringForKey:kGhosttyPreferenceKey];
    GhosttyColorScheme *scheme = [self schemeWithIdentifier:stored];
    // Default level so it survives in `log show`: a bug report can then tell
    // "wrong preference location" from "rendering bug".
    os_log(sLog, "Color scheme %{public}@ (stored value: %{public}@)",
           scheme.identifier, stored ?: @"none");
    return scheme;
}

+ (void)storeScheme:(GhosttyColorScheme *)scheme
{
    ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:kGhosttyModuleName];
    [defaults setObject:scheme.identifier forKey:kGhosttyPreferenceKey];
    // The System Settings preview and the full-screen saver run in different
    // processes. Flush now so the next full-screen activation reads it.
    [defaults synchronize];
    os_log(sLog, "Stored color scheme %{public}@", scheme.identifier);
}

@end
