#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "session_badge.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // When true the window is not shown after the first frame (launch with
  // --minimized, i.e. start at login into the tray). The Flutter engine keeps
  // running; the app shows the window itself later.
  void SetStartHidden(bool start_hidden) { start_hidden_ = start_hidden; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  bool start_hidden_ = false;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The "being controlled" badge: a window of its own, so it keeps showing
  // while this window is hidden in the tray.
  std::unique_ptr<SessionBadge> badge_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
