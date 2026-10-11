#ifndef RUNNER_SESSION_BADGE_H_
#define RUNNER_SESSION_BADGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

namespace Gdiplus {
class Bitmap;
}  // namespace Gdiplus

// The mandatory "being controlled" badge (docs/PROTOCOL.md section 9): a
// topmost, non-activating tool window in the top-right corner of the primary
// monitor, independent of the Flutter window (which may be hidden in the
// tray). Driven by the method channel `io.thelxis/badge`:
//   show {label, stopLabel, sinceMs, controlActive, peers} / dismiss
//   native -> Dart: stopPressed
// The elapsed time is ticked here once per second.
class SessionBadge {
 public:
  explicit SessionBadge(flutter::BinaryMessenger* messenger);
  ~SessionBadge();

  SessionBadge(const SessionBadge&) = delete;
  SessionBadge& operator=(const SessionBadge&) = delete;

 private:
  using MethodCallT = flutter::MethodCall<flutter::EncodableValue>;
  using MethodResultT = flutter::MethodResult<flutter::EncodableValue>;

  void OnMethodCall(const MethodCallT& call,
                    std::unique_ptr<MethodResultT> result);
  void Show(const std::wstring& label, const std::wstring& stop_label,
            int64_t since_ms, bool control_active);
  void Dismiss();

  bool CreateBadgeWindow();
  void DestroyBadgeWindow();
  // Paints into a premultiplied-alpha bitmap and hands it to the layered
  // window together with its (re)computed position.
  void Render();
  void Tick();

  LRESULT HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                        LPARAM lparam) noexcept;
  static LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) noexcept;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  ULONG_PTR gdiplus_token_ = 0;
  Gdiplus::Bitmap* icon_ = nullptr;

  std::wstring label_;
  std::wstring stop_label_;
  int64_t since_ms_ = 0;
  bool control_active_ = false;

  // Stop button, in window pixels (updated on every render).
  RECT button_rect_ = {0, 0, 0, 0};
  bool hover_ = false;
  bool pressed_ = false;
  bool tracking_leave_ = false;
};

#endif  // RUNNER_SESSION_BADGE_H_
