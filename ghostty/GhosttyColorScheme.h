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

/// Rows in every bundled frame. Body gradients are precomputed per row.
FOUNDATION_EXPORT const NSUInteger GhosttyColorSchemeRowCount;

/// A color scheme is a background, a body color for the plain glyphs, and an
/// accent color for the glyphs inside `<span class="b">…</span>`, all opaque
/// sRGB. A scheme may replace the flat body color with a vertical gradient:
/// four stops interpolated by row, top to bottom. The built-in schemes live
/// in a static table in popup order. The identifier is the value stored in
/// ScreenSaverDefaults and must never change once shipped.
@interface GhosttyColorScheme : NSObject

// Instances come from the table only. A plain -init would carry NULL colors.
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) CGColorRef backgroundColor;
/// The flat body color. On a gradient scheme it is never drawn; use
/// bodyColorForRow: for the color of a row.
@property (nonatomic, readonly) CGColorRef bodyColor;
@property (nonatomic, readonly) CGColorRef accentColor;

/// YES when the body is drawn as a per-row gradient instead of bodyColor.
@property (nonatomic, readonly) BOOL hasBodyGradient;

/// The body color for one row, 0 at the top. Flat schemes return bodyColor
/// for every row. Rows past GhosttyColorSchemeRowCount use the last row.
///
/// Gradient rows are interpolated in sRGB between four stops, in integer
/// arithmetic so every architecture produces the same 8-bit value. With
/// R = rows - 1, k = min(2, 3 * row / R) (integer division) and
/// n = 3 * row - R * k, each 8-bit component is
/// (A * (R - n) + B * n) / R rounded half up, where A is the component of
/// stops[k] and B of stops[k + 1]. The rendering harness recomputes this to
/// check the bundle.
- (CGColorRef)bodyColorForRow:(NSUInteger)row;

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
