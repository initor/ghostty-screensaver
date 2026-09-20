//
//  GhosttyColorScheme.h
//  ghostty
//
//  SPDX-License-Identifier: MIT
//  Created by Wayne Wen on 9/19/26.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted on the default NSNotificationCenter by the Options sheet whenever
/// the user changes the popup, clicks OK, or clicks Cancel. The userInfo
/// carries the scheme identifier under GhosttyColorSchemeIdentifierKey.
/// Every GhosttyView in the process observes it. The sheet holds no
/// reference to any view: on macOS 26 the host can create two preview
/// instances and ask either one for the sheet, so a direct pointer could
/// update the invisible one.
FOUNDATION_EXPORT NSNotificationName const GhosttyColorSchemeDidChangeNotification;
FOUNDATION_EXPORT NSString * const GhosttyColorSchemeIdentifierKey;

/// A color scheme is three opaque sRGB colors: the background, the body
/// glyphs, and the accent glyphs inside `<span class="b">…</span>`. The built-in
/// schemes live in a static table in popup order. The identifier is the
/// value stored in ScreenSaverDefaults and must never change once shipped.
@interface GhosttyColorScheme : NSObject

// Instances come from the table only. A plain -init would carry NULL colors.
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) CGColorRef backgroundColor;
@property (nonatomic, readonly) CGColorRef bodyColor;
@property (nonatomic, readonly) CGColorRef accentColor;

/// All schemes in table (popup) order. The first row is the fallback.
+ (NSArray<GhosttyColorScheme *> *)allSchemes;

/// Case-insensitive lookup after trimming whitespace. A missing, empty, or
/// unknown identifier resolves to the fallback scheme. Never returns nil.
+ (GhosttyColorScheme *)schemeWithIdentifier:(nullable NSString *)identifier;

/// Reads `ColorScheme` from this saver's ScreenSaverDefaults and resolves it
/// with +schemeWithIdentifier:. A read creates no preference file.
+ (GhosttyColorScheme *)storedScheme;

/// Writes the identifier to ScreenSaverDefaults and synchronizes, so the
/// full-screen host process sees it when it next creates a view.
+ (void)storeScheme:(GhosttyColorScheme *)scheme;

@end

NS_ASSUME_NONNULL_END
