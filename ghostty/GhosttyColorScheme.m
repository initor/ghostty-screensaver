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

const NSUInteger GhosttyColorSchemeRowCount = 41;

typedef struct {
    const char *identifier;    // stored value, lowercase ASCII
    const char *displayName;   // popup title, UTF-8
    uint32_t background;       // 0xRRGGBB, sRGB
    uint32_t body;             // flat body color, and the fallback when gradient is all zero
    uint32_t accent;
    uint32_t gradient[4];      // body gradient stops, top to bottom; all zero = flat body
} GhosttyColorSchemeSpec;

// Table order is popup order. Row 0 is the fallback and draws exactly what
// every version before 1.8.0 drew. The Catppuccin rows use palette 1.8.0
// (MIT, Copyright (c) 2021 Catppuccin): base for the background, blue for
// the halo, and the body fades peach, pink, mauve, blue from the top row to
// the bottom row. The flat text color stays as the documented fallback.
static const GhosttyColorSchemeSpec kGhosttySchemes[] = {
    { "classic",              "Classic",              0x000000, 0xd7d7d7, 0x0000e6, { 0, 0, 0, 0 } },
    { "catppuccin-frappe",    "Catppuccin Frappé",    0x303446, 0xc6d0f5, 0x8caaee, { 0xef9f76, 0xf4b8e4, 0xca9ee6, 0x8caaee } },
    { "catppuccin-macchiato", "Catppuccin Macchiato", 0x24273a, 0xcad3f5, 0x8aadf4, { 0xf5a97f, 0xf5bde6, 0xc6a0f6, 0x8aadf4 } },
    { "catppuccin-mocha",     "Catppuccin Mocha",     0x1e1e2e, 0xcdd6f4, 0x89b4fa, { 0xfab387, 0xf5c2e7, 0xcba6f7, 0x89b4fa } },
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

// One gradient row, in integer arithmetic. A float blend lands on exact
// .5 ties for a third of the components, and whether clang fuses the
// multiply-add then decides the rounding, so the arm64 and x86_64 slices
// of one universal binary would disagree by 1/255 on a few rows. Integer
// math gives every architecture and compiler the same 8-bit value, and a
// fully covered pixel in an 8-bit sRGB bitmap equals it exactly, which is
// what the rendering harness asserts.
static CGColorRef GhosttyCreateGradientRowColor(const uint32_t stops[4], NSUInteger row, NSUInteger rows)
{
    NSUInteger span = (rows > 1) ? rows - 1 : 1;          // R in the header formula
    NSUInteger k = MIN((NSUInteger)2, 3 * row / span);    // segment: 0, 1 or 2
    NSUInteger n = 3 * row - span * k;                    // position inside it, 0...R
    CGFloat c[3];
    for (NSUInteger i = 0; i < 3; i++) {
        unsigned shift = (unsigned)(16 - 8 * i);
        NSUInteger a = (stops[k] >> shift) & 0xff;
        NSUInteger b = (stops[k + 1] >> shift) & 0xff;
        NSUInteger numerator = a * (span - n) + b * n;
        NSUInteger value = (2 * numerator + span) / (2 * span);   // round half up
        c[i] = (CGFloat)value / 255.0;
    }
    return CGColorCreateSRGB(c[0], c[1], c[2], 1.0);
}

@interface GhosttyColorScheme ()
// Row colors for gradient schemes, GhosttyColorSchemeRowCount entries.
// Empty for flat schemes.
@property (nonatomic, strong) NSArray *rowColors;
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

        BOOL gradient = spec->gradient[0] || spec->gradient[1] || spec->gradient[2] || spec->gradient[3];
        NSMutableArray *rows = [NSMutableArray arrayWithCapacity:gradient ? GhosttyColorSchemeRowCount : 0];
        for (NSUInteger row = 0; gradient && row < GhosttyColorSchemeRowCount; row++) {
            CGColorRef color = GhosttyCreateGradientRowColor(spec->gradient, row, GhosttyColorSchemeRowCount);
            [rows addObject:(__bridge id)color];   // the array retains it
            CGColorRelease(color);
        }
        _rowColors = [rows copy];
    }
    return self;
}

- (BOOL)hasBodyGradient
{
    return self.rowColors.count > 0;
}

- (CGColorRef)bodyColorForRow:(NSUInteger)row
{
    NSArray *rows = self.rowColors;
    if (rows.count == 0) {
        return self.bodyColor;
    }
    return (__bridge CGColorRef)rows[MIN(row, rows.count - 1)];
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
