#include "session_badge.h"

#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cwchar>
#include <initializer_list>
#include <memory>
#include <string>
#include <variant>

// GDI+ headers use unqualified min/max, which NOMINMAX (set for the runner)
// removes from <windows.h>.
using std::max;
using std::min;

#pragma warning(push, 0)
#include <objidl.h>
#include <gdiplus.h>
#pragma warning(pop)

#include "resource.h"

namespace {

constexpr wchar_t kWindowClassName[] = L"THELXIS_SESSION_BADGE";
constexpr UINT_PTR kTickTimerId = 1;
constexpr UINT kTickIntervalMs = 1000;

// Logical size at 96 DPI.
constexpr float kBadgeWidth = 300.0f;
constexpr float kBadgeHeight = 56.0f;
constexpr float kMargin = 16.0f;
constexpr float kCornerRadius = 14.0f;

// WDA_EXCLUDEFROMCAPTURE (Windows 10 2004+); not defined by older SDK headers.
constexpr DWORD kExcludeFromCapture = 0x00000011;

// Milliseconds between 1601-01-01 (FILETIME epoch) and 1970-01-01.
constexpr uint64_t kFileTimeToUnixMs = 11644473600000ULL;

std::wstring Widen(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        &wide[0], length);
  return wide;
}

int64_t NowUnixMs() {
  FILETIME ft;
  ::GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER value;
  value.LowPart = ft.dwLowDateTime;
  value.HighPart = ft.dwHighDateTime;
  const uint64_t ms = value.QuadPart / 10000ULL;
  return static_cast<int64_t>(ms - kFileTimeToUnixMs);
}

// HH:MM:SS, hours uncapped, a clock that moved backwards shows zero.
std::wstring FormatElapsed(int64_t since_ms) {
  int64_t total = (NowUnixMs() - since_ms) / 1000;
  if (total < 0) {
    total = 0;
  }
  wchar_t buffer[32];
  swprintf_s(buffer, L"%02d:%02d:%02d", static_cast<int>(total / 3600),
             static_cast<int>((total % 3600) / 60),
             static_cast<int>(total % 60));
  return buffer;
}

RECT PrimaryWorkArea() {
  const POINT origin = {0, 0};
  HMONITOR monitor = ::MonitorFromPoint(origin, MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO info = {};
  info.cbSize = sizeof(info);
  RECT area = {0, 0, 1280, 720};
  if (::GetMonitorInfoW(monitor, &info)) {
    area = info.rcWork;
  }
  return area;
}

int Px(float logical, float scale) {
  return static_cast<int>(std::lround(logical * scale));
}

// First installed family from |names|; the badge works with any of them.
// Variable fonts may be listed by GDI+ without a bold face, which would make
// DrawString silently draw nothing, so the needed |style| is checked as well.
std::unique_ptr<Gdiplus::FontFamily> PickFamily(
    std::initializer_list<const wchar_t*> names, INT style) {
  for (const wchar_t* name : names) {
    auto family = std::make_unique<Gdiplus::FontFamily>(name);
    if (family->IsAvailable() && family->IsStyleAvailable(style)) {
      return family;
    }
  }
  return std::unique_ptr<Gdiplus::FontFamily>(
      Gdiplus::FontFamily::GenericSansSerif()->Clone());
}

void AddRoundedRect(Gdiplus::GraphicsPath* path, const Gdiplus::RectF& rect,
                    float radius) {
  const float d = radius * 2.0f;
  path->AddArc(rect.X, rect.Y, d, d, 180.0f, 90.0f);
  path->AddArc(rect.GetRight() - d, rect.Y, d, d, 270.0f, 90.0f);
  path->AddArc(rect.GetRight() - d, rect.GetBottom() - d, d, d, 0.0f, 90.0f);
  path->AddArc(rect.X, rect.GetBottom() - d, d, d, 90.0f, 90.0f);
  path->CloseFigure();
}

}  // namespace

SessionBadge::SessionBadge(flutter::BinaryMessenger* messenger) {
  Gdiplus::GdiplusStartupInput startup_input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &startup_input, nullptr);

  HICON icon = static_cast<HICON>(
      ::LoadImageW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                   IMAGE_ICON, 64, 64, LR_DEFAULTCOLOR));
  if (icon != nullptr) {
    icon_ = Gdiplus::Bitmap::FromHICON(icon);
    ::DestroyIcon(icon);
    if (icon_ != nullptr && icon_->GetLastStatus() != Gdiplus::Ok) {
      delete icon_;
      icon_ = nullptr;
    }
  }

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "io.thelxis/badge",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const MethodCallT& call, std::unique_ptr<MethodResultT> result) {
        OnMethodCall(call, std::move(result));
      });
}

SessionBadge::~SessionBadge() {
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
  }
  DestroyBadgeWindow();
  if (class_registered_) {
    ::UnregisterClassW(kWindowClassName, ::GetModuleHandleW(nullptr));
  }
  delete icon_;  // must go before GdiplusShutdown
  icon_ = nullptr;
  if (gdiplus_token_ != 0) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
  }
}

// ---- channel ----------------------------------------------------------------

void SessionBadge::OnMethodCall(const MethodCallT& call,
                                std::unique_ptr<MethodResultT> result) {
  if (call.method_name() == "show") {
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (args == nullptr) {
      result->Error("bad_args", "show expects a map");
      return;
    }
    auto find = [args](const char* key) -> const flutter::EncodableValue* {
      auto it = args->find(flutter::EncodableValue(key));
      return it == args->end() ? nullptr : &it->second;
    };

    std::wstring label;
    std::wstring stop_label;
    int64_t since_ms = NowUnixMs();
    bool control = false;
    if (const auto* v = find("label")) {
      if (const auto* s = std::get_if<std::string>(v)) {
        label = Widen(*s);
      }
    }
    if (const auto* v = find("stopLabel")) {
      if (const auto* s = std::get_if<std::string>(v)) {
        stop_label = Widen(*s);
      }
    }
    if (const auto* v = find("sinceMs")) {
      if (const auto* i64 = std::get_if<int64_t>(v)) {
        since_ms = *i64;
      } else if (const auto* i32 = std::get_if<int32_t>(v)) {
        since_ms = *i32;
      }
    }
    if (const auto* v = find("controlActive")) {
      if (const auto* b = std::get_if<bool>(v)) {
        control = *b;
      }
    }
    Show(label, stop_label, since_ms, control);
    result->Success();
  } else if (call.method_name() == "dismiss") {
    Dismiss();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void SessionBadge::Show(const std::wstring& label,
                        const std::wstring& stop_label, int64_t since_ms,
                        bool control_active) {
  label_ = label;
  stop_label_ = stop_label;
  since_ms_ = since_ms;
  control_active_ = control_active;
  if (hwnd_ == nullptr && !CreateBadgeWindow()) {
    return;
  }
  Render();
  ::ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
}

void SessionBadge::Dismiss() {
  DestroyBadgeWindow();
}

// ---- window -----------------------------------------------------------------

bool SessionBadge::CreateBadgeWindow() {
  HINSTANCE instance = ::GetModuleHandleW(nullptr);
  if (!class_registered_) {
    WNDCLASSEXW window_class = {};
    window_class.cbSize = sizeof(window_class);
    window_class.lpfnWndProc = SessionBadge::WindowProc;
    window_class.hInstance = instance;
    window_class.hCursor = ::LoadCursorW(nullptr, IDC_ARROW);
    window_class.lpszClassName = kWindowClassName;
    if (::RegisterClassExW(&window_class) == 0) {
      return false;
    }
    class_registered_ = true;
  }

  // Created in the top-right corner of the primary work area; Render() sets
  // the final size once the window's DPI is known.
  const RECT work = PrimaryWorkArea();
  const int width = static_cast<int>(kBadgeWidth);
  const int height = static_cast<int>(kBadgeHeight);
  hwnd_ = ::CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED,
      kWindowClassName, L"Thelxis session badge", WS_POPUP,
      work.right - width - static_cast<int>(kMargin),
      work.top + static_cast<int>(kMargin), width, height, nullptr, nullptr,
      instance, this);
  if (hwnd_ == nullptr) {
    return false;
  }

  // Keep it out of screenshots and screen sharing (the viewer does not need
  // to see it). Before Windows 10 2004 the value 0x11 is accepted but behaves
  // like WDA_MONITOR (a black rectangle in captures); in that case fall back to
  // "capturable" so the viewer at least sees the badge as it is.
  ::SetWindowDisplayAffinity(hwnd_, kExcludeFromCapture);
  DWORD affinity = 0;
  if (!::GetWindowDisplayAffinity(hwnd_, &affinity) ||
      affinity != kExcludeFromCapture) {
    ::SetWindowDisplayAffinity(hwnd_, 0);
  }

  ::SetTimer(hwnd_, kTickTimerId, kTickIntervalMs, nullptr);
  return true;
}

void SessionBadge::DestroyBadgeWindow() {
  if (hwnd_ == nullptr) {
    return;
  }
  HWND window = hwnd_;
  hwnd_ = nullptr;
  hover_ = false;
  pressed_ = false;
  tracking_leave_ = false;
  ::KillTimer(window, kTickTimerId);
  ::DestroyWindow(window);
}

void SessionBadge::Tick() {
  if (hwnd_ == nullptr) {
    return;
  }
  // Re-assert topmost: a full-screen window or another topmost window can
  // take the top of the z-order.
  ::SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  Render();
}

// ---- painting ---------------------------------------------------------------

void SessionBadge::Render() {
  if (hwnd_ == nullptr) {
    return;
  }
  UINT dpi = ::GetDpiForWindow(hwnd_);
  if (dpi == 0) {
    dpi = 96;
  }
  const float scale = static_cast<float>(dpi) / 96.0f;
  const int width = Px(kBadgeWidth, scale);
  const int height = Px(kBadgeHeight, scale);

  const RECT work = PrimaryWorkArea();
  POINT position = {work.right - width - Px(kMargin, scale),
                    work.top + Px(kMargin, scale)};

  BITMAPINFO info = {};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;  // top-down
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;

  HDC screen = ::GetDC(nullptr);
  HDC memory = ::CreateCompatibleDC(screen);
  void* bits = nullptr;
  HBITMAP dib =
      ::CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (dib == nullptr || bits == nullptr) {
    ::DeleteDC(memory);
    ::ReleaseDC(nullptr, screen);
    return;
  }
  HGDIOBJ previous = ::SelectObject(memory, dib);

  {
    Gdiplus::Bitmap surface(width, height, width * 4, PixelFormat32bppPARGB,
                            static_cast<BYTE*>(bits));
    Gdiplus::Graphics g(&surface);
    g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
    g.SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
    g.SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
    g.SetTextRenderingHint(Gdiplus::TextRenderingHintAntiAlias);
    g.Clear(Gdiplus::Color(0, 0, 0, 0));

    const float w = static_cast<float>(width);
    const float h = static_cast<float>(height);

    // Card: translucent dark violet. A layered per-pixel-alpha window cannot
    // use the DWM backdrop, so this is a "faux glass" gradient plus a
    // hairline highlight.
    Gdiplus::GraphicsPath card;
    AddRoundedRect(&card, Gdiplus::RectF(0.0f, 0.0f, w, h),
                   kCornerRadius * scale);
    Gdiplus::LinearGradientBrush background(
        Gdiplus::PointF(0.0f, 0.0f), Gdiplus::PointF(0.0f, h),
        Gdiplus::Color(228, 40, 35, 66), Gdiplus::Color(228, 22, 19, 40));
    g.FillPath(&background, &card);

    Gdiplus::GraphicsPath highlight;
    AddRoundedRect(&highlight,
                   Gdiplus::RectF(0.5f, 0.5f, w - 1.0f, h - 1.0f),
                   kCornerRadius * scale - 0.5f);
    Gdiplus::Pen highlight_pen(Gdiplus::Color(36, 255, 255, 255), 1.0f);
    g.DrawPath(&highlight_pen, &highlight);

    // Accent outline: soft violet while viewing, strong red when controlling.
    const float outline = (control_active_ ? 2.0f : 1.0f) * scale;
    Gdiplus::GraphicsPath edge;
    AddRoundedRect(&edge,
                   Gdiplus::RectF(outline / 2.0f, outline / 2.0f, w - outline,
                                  h - outline),
                   kCornerRadius * scale - outline / 2.0f);
    Gdiplus::Pen accent_pen(control_active_ ? Gdiplus::Color(235, 255, 90, 95)
                                            : Gdiplus::Color(130, 108, 76, 245),
                            outline);
    g.DrawPath(&accent_pen, &edge);

    // Logo.
    const Gdiplus::RectF icon_rect(12.0f * scale, (h - 32.0f * scale) / 2.0f,
                                   32.0f * scale, 32.0f * scale);
    if (icon_ != nullptr) {
      g.DrawImage(icon_, icon_rect);
    } else {
      Gdiplus::SolidBrush fallback(Gdiplus::Color(255, 108, 76, 245));
      g.FillEllipse(&fallback, icon_rect);
    }

    auto text_family =
        PickFamily({L"Segoe UI Variable Text", L"Segoe UI", L"Arial"},
                   Gdiplus::FontStyleBold);
    auto mono_family = PickFamily({L"Cascadia Mono", L"Consolas", L"Segoe UI"},
                                  Gdiplus::FontStyleRegular);
    Gdiplus::Font label_font(text_family.get(), 13.0f * scale,
                             Gdiplus::FontStyleBold, Gdiplus::UnitPixel);
    Gdiplus::Font timer_font(mono_family.get(), 12.0f * scale,
                             Gdiplus::FontStyleRegular, Gdiplus::UnitPixel);
    Gdiplus::Font button_font(text_family.get(), 12.0f * scale,
                              Gdiplus::FontStyleBold, Gdiplus::UnitPixel);

    Gdiplus::StringFormat left_format;
    left_format.SetAlignment(Gdiplus::StringAlignmentNear);
    left_format.SetLineAlignment(Gdiplus::StringAlignmentNear);
    left_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    left_format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

    Gdiplus::StringFormat center_format;
    center_format.SetAlignment(Gdiplus::StringAlignmentCenter);
    center_format.SetLineAlignment(Gdiplus::StringAlignmentCenter);
    center_format.SetTrimming(Gdiplus::StringTrimmingEllipsisCharacter);
    center_format.SetFormatFlags(Gdiplus::StringFormatFlagsNoWrap);

    // Stop button, sized to its caption (64..120 logical px wide).
    Gdiplus::RectF measured;
    g.MeasureString(stop_label_.c_str(), -1, &button_font,
                    Gdiplus::RectF(0.0f, 0.0f, 1000.0f, 100.0f), &center_format,
                    &measured);
    const float button_w = std::min(
        std::max(64.0f * scale, measured.Width + 24.0f * scale), 120.0f * scale);
    const float button_h = 28.0f * scale;
    const Gdiplus::RectF button(w - 12.0f * scale - button_w,
                                (h - button_h) / 2.0f, button_w, button_h);
    button_rect_.left = static_cast<LONG>(std::lround(button.X));
    button_rect_.top = static_cast<LONG>(std::lround(button.Y));
    button_rect_.right = static_cast<LONG>(std::lround(button.GetRight()));
    button_rect_.bottom = static_cast<LONG>(std::lround(button.GetBottom()));

    Gdiplus::GraphicsPath button_path;
    AddRoundedRect(&button_path, button, 8.0f * scale);
    Gdiplus::Color button_color(255, 232, 69, 85);
    if (pressed_ && hover_) {
      button_color = Gdiplus::Color(255, 184, 48, 64);
    } else if (hover_) {
      button_color = Gdiplus::Color(255, 245, 87, 102);
    }
    Gdiplus::SolidBrush button_brush(button_color);
    g.FillPath(&button_brush, &button_path);
    Gdiplus::SolidBrush white(Gdiplus::Color(255, 255, 255, 255));
    g.DrawString(stop_label_.c_str(), -1, &button_font, button, &center_format,
                 &white);

    // Label, status dot and timer.
    const float text_x = 52.0f * scale;
    const float text_w = button.X - 8.0f * scale - text_x;
    Gdiplus::SolidBrush label_brush(Gdiplus::Color(242, 255, 255, 255));
    g.DrawString(label_.c_str(), -1, &label_font,
                 Gdiplus::RectF(text_x, 9.0f * scale, text_w, 20.0f * scale),
                 &left_format, &label_brush);

    Gdiplus::SolidBrush dot_brush(control_active_
                                      ? Gdiplus::Color(255, 255, 90, 95)
                                      : Gdiplus::Color(255, 108, 76, 245));
    g.FillEllipse(&dot_brush, text_x, 36.0f * scale, 8.0f * scale,
                  8.0f * scale);

    Gdiplus::SolidBrush timer_brush(Gdiplus::Color(190, 255, 255, 255));
    const std::wstring elapsed = FormatElapsed(since_ms_);
    g.DrawString(elapsed.c_str(), -1, &timer_font,
                 Gdiplus::RectF(text_x + 14.0f * scale, 31.0f * scale,
                                text_w - 14.0f * scale, 18.0f * scale),
                 &left_format, &timer_brush);
  }
  ::GdiFlush();

  SIZE size = {width, height};
  POINT source = {0, 0};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  ::UpdateLayeredWindow(hwnd_, screen, &position, &size, memory, &source, 0,
                        &blend, ULW_ALPHA);

  ::SelectObject(memory, previous);
  ::DeleteObject(dib);
  ::DeleteDC(memory);
  ::ReleaseDC(nullptr, screen);
}

// ---- messages ---------------------------------------------------------------

LRESULT CALLBACK SessionBadge::WindowProc(HWND hwnd, UINT message,
                                          WPARAM wparam,
                                          LPARAM lparam) noexcept {
  SessionBadge* self = nullptr;
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
    self = static_cast<SessionBadge*>(create->lpCreateParams);
    ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  } else {
    self = reinterpret_cast<SessionBadge*>(
        ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  }
  if (self != nullptr) {
    return self->HandleMessage(hwnd, message, wparam, lparam);
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}

LRESULT SessionBadge::HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;  // never take focus from the user's window

    case WM_ERASEBKGND:
      return 1;

    case WM_CLOSE:
      return 0;  // only Dismiss() removes the badge

    case WM_TIMER:
      if (wparam == kTickTimerId) {
        Tick();
        return 0;
      }
      break;

    case WM_DISPLAYCHANGE:
    case WM_DPICHANGED:
    case WM_SETTINGCHANGE:
      Render();  // recomputes DPI scale and corner position
      return 0;

    case WM_LBUTTONDOWN: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (::PtInRect(&button_rect_, point)) {
        pressed_ = true;
        hover_ = true;
        ::SetCapture(hwnd);
        Render();
      }
      return 0;
    }

    case WM_LBUTTONUP: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (pressed_) {
        pressed_ = false;
        ::ReleaseCapture();
        const bool inside = ::PtInRect(&button_rect_, point) != FALSE;
        hover_ = inside;
        Render();
        if (inside && channel_) {
          // Ends the sessions (core's job). The badge itself is only
          // dismissed by core once no session remains.
          channel_->InvokeMethod("stopPressed", nullptr);
        }
      }
      return 0;
    }

    case WM_MOUSEMOVE: {
      const POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const bool inside = ::PtInRect(&button_rect_, point) != FALSE;
      if (!tracking_leave_) {
        TRACKMOUSEEVENT track = {};
        track.cbSize = sizeof(track);
        track.dwFlags = TME_LEAVE;
        track.hwndTrack = hwnd;
        tracking_leave_ = ::TrackMouseEvent(&track) != FALSE;
      }
      if (inside != hover_) {
        hover_ = inside;
        Render();
      }
      return 0;
    }

    case WM_CAPTURECHANGED:
      // Capture can be lost without a WM_LBUTTONUP (released outside a
      // background window); do not leave the button drawn as pressed.
      if (pressed_) {
        pressed_ = false;
        Render();
      }
      return 0;

    case WM_MOUSELEAVE:
      tracking_leave_ = false;
      if (hover_ && !pressed_) {
        hover_ = false;
        Render();
      }
      return 0;

    case WM_NCDESTROY:
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
      break;
  }
  return ::DefWindowProcW(hwnd, message, wparam, lparam);
}
