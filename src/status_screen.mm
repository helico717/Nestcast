#include "nestcast/status_screen.h"

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include <ctime>

namespace nestcast {
namespace {

NSAttributedString* Text(NSString* text, CGFloat font_size, CGFloat gray) {
  CTFontRef font =
      CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, font_size, CFSTR("ko"));
  CGColorRef color = CGColorCreateGenericGray(gray, 1.0);
  NSDictionary* attrs = @{
    (__bridge id)kCTFontAttributeName : (__bridge id)font,
    (__bridge id)kCTForegroundColorAttributeName : (__bridge id)color,
  };
  NSAttributedString* s = [[NSAttributedString alloc] initWithString:text
                                                          attributes:attrs];
  CGColorRelease(color);
  CFRelease(font);
  return s;
}

void DrawCentered(CGContextRef ctx,
                  NSAttributedString* s,
                  CGFloat center_y,
                  int width) {
  CTLineRef line =
      CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)s);
  CGFloat ascent = 0, descent = 0;
  const double w = CTLineGetTypographicBounds(line, &ascent, &descent, nullptr);
  CGContextSetTextPosition(ctx, (width - w) / 2.0,
                           center_y - (ascent - descent) / 2.0);
  CTLineDraw(line, ctx);
  CFRelease(line);
}

}  // namespace

StatusScreen::StatusScreen(int width, int height)
    : width_(width), height_(height), rgba_(new uint8_t[width * height * 4]) {}

StatusScreen::~StatusScreen() = default;

bool StatusScreen::Update(uint8_t* i420) {
  const time_t now = time(nullptr);
  struct tm lt;
  localtime_r(&now, &lt);
  const int minute = lt.tm_hour * 60 + lt.tm_min;
  if (minute == last_minute_) {
    return false;
  }
  last_minute_ = minute;

  @autoreleasepool {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        rgba_.get(), width_, height_, 8, width_ * 4, cs,
        static_cast<uint32_t>(kCGImageAlphaNoneSkipLast) |
            static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGColorSpaceRelease(cs);
    // Near-black background (not pure black, so the screen reads as "on").
    CGContextSetRGBFillColor(ctx, 0.04, 0.04, 0.05, 1.0);
    CGContextFillRect(ctx, CGRectMake(0, 0, width_, height_));
    CGContextSetShouldAntialias(ctx, true);

    // 12-hour clock with 오전/오후, e.g. "오후 11:17".
    const int hour12 = lt.tm_hour % 12 == 0 ? 12 : lt.tm_hour % 12;
    NSMutableAttributedString* clock = [[NSMutableAttributedString alloc]
        initWithAttributedString:Text(lt.tm_hour < 12 ? @"오전 " : @"오후 ",
                                      height_ * 0.09, 0.36)];
    [clock appendAttributedString:
               Text([NSString stringWithFormat:@"%d:%02d", hour12, lt.tm_min],
                    height_ * 0.26, 0.42)];
    // Date line, e.g. "10월 19일 월요일" (local time zone, Korean locale).
    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"ko_KR"];
    fmt.dateFormat = @"M월 d일 EEEE";
    NSString* date = [fmt stringFromDate:[NSDate date]];
    // CoreGraphics' origin is bottom-left.
    DrawCentered(ctx, Text(date, height_ * 0.06, 0.32), height_ * 0.72, width_);
    DrawCentered(ctx, clock, height_ * 0.52, width_);
    DrawCentered(ctx, Text(@"Mac 오디오 재생 중", height_ * 0.055, 0.30),
                 height_ * 0.32, width_);
    CGContextRelease(ctx);
  }

  // RGBA (top row first in memory for a bitmap context) -> I420 (BT.601,
  // limited range).
  uint8_t* y_plane = i420;
  uint8_t* u_plane = i420 + width_ * height_;
  uint8_t* v_plane = u_plane + (width_ / 2) * (height_ / 2);
  for (int row = 0; row < height_; ++row) {
    const uint8_t* p = rgba_.get() + row * width_ * 4;
    for (int col = 0; col < width_; ++col, p += 4) {
      const int r = p[0], g = p[1], b = p[2];
      y_plane[row * width_ + col] =
          static_cast<uint8_t>(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
  }
  for (int row = 0; row < height_ / 2; ++row) {
    for (int col = 0; col < width_ / 2; ++col) {
      const uint8_t* p = rgba_.get() + (2 * row * width_ + 2 * col) * 4;
      const int r = p[0], g = p[1], b = p[2];
      u_plane[row * (width_ / 2) + col] =
          static_cast<uint8_t>(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
      v_plane[row * (width_ / 2) + col] =
          static_cast<uint8_t>(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
    }
  }
  return true;
}

}  // namespace nestcast
