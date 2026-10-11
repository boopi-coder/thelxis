#include "session_badge.h"

#include <cairo.h>
#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>
#include <pango/pangocairo.h>

#include <cmath>
#include <cstring>

namespace {

constexpr int kWidth = 300;
constexpr int kHeight = 56;
constexpr int kMargin = 16;
constexpr double kRadius = 14.0;
constexpr int kButtonHeight = 28;

}  // namespace

struct SessionBadge {
  FlMethodChannel* channel = nullptr;
  GtkWidget* window = nullptr;  // null while dismissed
  GdkPixbuf* icon = nullptr;
  gchar* label = nullptr;
  gchar* stop_label = nullptr;
  gint64 since_ms = 0;
  gboolean control_active = FALSE;
  guint timer_id = 0;
  gboolean hover_button = FALSE;
  gboolean pressed_button = FALSE;
  GdkRectangle button_rect = {0, 0, 0, 0};
};

// ---- helpers ---------------------------------------------------------------

static void rounded_rect(cairo_t* cr, double x, double y, double w, double h,
                         double r) {
  cairo_new_sub_path(cr);
  cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
  cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
  cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
  cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
  cairo_close_path(cr);
}

static bool point_in_rect(const GdkRectangle& rect, double x, double y) {
  return x >= rect.x && x <= rect.x + rect.width && y >= rect.y &&
         y <= rect.y + rect.height;
}

static gchar* format_elapsed(gint64 since_ms) {
  gint64 total = (g_get_real_time() / 1000 - since_ms) / 1000;
  if (total < 0) {
    total = 0;
  }
  return g_strdup_printf("%02d:%02d:%02d", static_cast<int>(total / 3600),
                         static_cast<int>((total % 3600) / 60),
                         static_cast<int>(total % 60));
}

// The icon ships next to the executable as a Flutter asset:
//   <exe dir>/data/flutter_assets/assets/icon/app_icon.png
static GdkPixbuf* load_icon() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", nullptr);
  if (exe == nullptr) {
    return nullptr;
  }
  g_autofree gchar* dir = g_path_get_dirname(exe);
  g_autofree gchar* path =
      g_build_filename(dir, "data", "flutter_assets", "assets", "icon",
                       "app_icon.png", nullptr);
  return gdk_pixbuf_new_from_file_at_scale(path, 64, 64, TRUE, nullptr);
}

static void draw_text(cairo_t* cr, const char* text, const char* family,
                      double size_px, PangoWeight weight, double x, double y,
                      int max_width, double r, double g, double b, double a,
                      int* out_width, int* out_height) {
  PangoLayout* layout = pango_cairo_create_layout(cr);
  PangoFontDescription* desc = pango_font_description_new();
  pango_font_description_set_family(desc, family);
  pango_font_description_set_weight(desc, weight);
  pango_font_description_set_absolute_size(desc, size_px * PANGO_SCALE);
  pango_layout_set_font_description(layout, desc);
  pango_layout_set_text(layout, text, -1);
  if (max_width > 0) {
    pango_layout_set_width(layout, max_width * PANGO_SCALE);
    pango_layout_set_ellipsize(layout, PANGO_ELLIPSIZE_END);
  }
  int w = 0;
  int h = 0;
  pango_layout_get_pixel_size(layout, &w, &h);
  if (out_width != nullptr) {
    *out_width = w;
  }
  if (out_height != nullptr) {
    *out_height = h;
  }
  if (a > 0) {
    cairo_set_source_rgba(cr, r, g, b, a);
    cairo_move_to(cr, x, y);
    pango_cairo_show_layout(cr, layout);
  }
  pango_font_description_free(desc);
  g_object_unref(layout);
}

// ---- drawing ---------------------------------------------------------------

static gboolean draw_cb(GtkWidget* widget, cairo_t* cr, gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);

  GdkScreen* screen = gtk_widget_get_screen(widget);
  const bool translucent =
      gdk_screen_get_rgba_visual(screen) != nullptr &&
      gdk_screen_is_composited(screen);

  // Clear to fully transparent first (or opaque dark without a compositor).
  cairo_save(cr);
  cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE);
  cairo_set_source_rgba(cr, 0.09, 0.08, 0.15, translucent ? 0.0 : 1.0);
  cairo_paint(cr);
  cairo_restore(cr);

  if (translucent) {
    // No real blur on X11: a translucent dark violet card is the closest we
    // can get without compositor-specific protocols.
    cairo_pattern_t* bg = cairo_pattern_create_linear(0, 0, 0, kHeight);
    cairo_pattern_add_color_stop_rgba(bg, 0.0, 0.15, 0.13, 0.24, 0.90);
    cairo_pattern_add_color_stop_rgba(bg, 1.0, 0.09, 0.08, 0.15, 0.90);
    rounded_rect(cr, 0, 0, kWidth, kHeight, kRadius);
    cairo_set_source(cr, bg);
    cairo_fill(cr);
    cairo_pattern_destroy(bg);
  }

  // Accent outline: soft violet for view-only, strong red when control is on.
  const bool control = self->control_active != FALSE;
  rounded_rect(cr, 1, 1, kWidth - 2, kHeight - 2, kRadius - 1);
  if (control) {
    cairo_set_source_rgba(cr, 1.0, 0.35, 0.37, 0.9);
    cairo_set_line_width(cr, 2.0);
  } else {
    cairo_set_source_rgba(cr, 0.42, 0.30, 0.96, 0.5);
    cairo_set_line_width(cr, 1.0);
  }
  cairo_stroke(cr);

  // Logo.
  if (self->icon != nullptr) {
    cairo_save(cr);
    cairo_translate(cr, 12, 12);
    cairo_scale(cr, 32.0 / gdk_pixbuf_get_width(self->icon),
                32.0 / gdk_pixbuf_get_height(self->icon));
    gdk_cairo_set_source_pixbuf(cr, self->icon, 0, 0);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BEST);
    cairo_paint(cr);
    cairo_restore(cr);
  } else {
    cairo_arc(cr, 28, 28, 14, 0, 2 * M_PI);
    cairo_set_source_rgba(cr, 0.42, 0.30, 0.96, 1.0);
    cairo_fill(cr);
  }

  // Stop button (right). Measure first, it decides the text width.
  const char* stop_text = self->stop_label != nullptr ? self->stop_label : "";
  int stop_w = 0;
  draw_text(cr, stop_text, "Sans", 12, PANGO_WEIGHT_BOLD, 0, 0, 0, 0, 0, 0, 0,
            &stop_w, nullptr);
  int button_w = stop_w + 24;
  if (button_w < 64) {
    button_w = 64;
  }
  if (button_w > 120) {
    button_w = 120;
  }
  self->button_rect.width = button_w;
  self->button_rect.height = kButtonHeight;
  self->button_rect.x = kWidth - 12 - button_w;
  self->button_rect.y = (kHeight - kButtonHeight) / 2;

  rounded_rect(cr, self->button_rect.x, self->button_rect.y, button_w,
               kButtonHeight, 8);
  if (self->pressed_button) {
    cairo_set_source_rgba(cr, 0.72, 0.19, 0.25, 1.0);
  } else if (self->hover_button) {
    cairo_set_source_rgba(cr, 0.96, 0.34, 0.40, 1.0);
  } else {
    cairo_set_source_rgba(cr, 0.91, 0.27, 0.33, 1.0);
  }
  cairo_fill(cr);

  int stop_h = 0;
  draw_text(cr, stop_text, "Sans", 12, PANGO_WEIGHT_BOLD, 0, 0, button_w - 12,
            0, 0, 0, 0, &stop_w, &stop_h);
  draw_text(cr, stop_text, "Sans", 12, PANGO_WEIGHT_BOLD,
            self->button_rect.x + (button_w - stop_w) / 2.0,
            self->button_rect.y + (kButtonHeight - stop_h) / 2.0, button_w - 12,
            1, 1, 1, 1, nullptr, nullptr);

  // Label and timer.
  const int text_x = 52;
  const int text_w = self->button_rect.x - 8 - text_x;
  draw_text(cr, self->label != nullptr ? self->label : "", "Sans", 13,
            PANGO_WEIGHT_BOLD, text_x, 7, text_w, 1, 1, 1, 0.95, nullptr,
            nullptr);

  cairo_arc(cr, text_x + 4, 40, 4, 0, 2 * M_PI);
  if (control) {
    cairo_set_source_rgba(cr, 1.0, 0.35, 0.37, 1.0);
  } else {
    cairo_set_source_rgba(cr, 0.42, 0.30, 0.96, 1.0);
  }
  cairo_fill(cr);

  g_autofree gchar* elapsed = format_elapsed(self->since_ms);
  draw_text(cr, elapsed, "Monospace", 12, PANGO_WEIGHT_NORMAL, text_x + 14, 32,
            text_w - 14, 1, 1, 1, 0.75, nullptr, nullptr);

  return FALSE;
}

// ---- window management -----------------------------------------------------

static void reposition(SessionBadge* self) {
  if (self->window == nullptr) {
    return;
  }
  GdkDisplay* display = gdk_display_get_default();
  if (display == nullptr) {
    return;
  }
  GdkMonitor* monitor = gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  if (monitor == nullptr) {
    return;
  }
  GdkRectangle area;
  gdk_monitor_get_workarea(monitor, &area);
  const gint x = area.x + area.width - kWidth - kMargin;
  const gint y = area.y + kMargin;

  gint current_x = 0;
  gint current_y = 0;
  gtk_window_get_position(GTK_WINDOW(self->window), &current_x, &current_y);
  if (current_x != x || current_y != y) {
    gtk_window_move(GTK_WINDOW(self->window), x, y);
  }
}

static void screen_changed_cb(GdkScreen* screen, gpointer user_data) {
  reposition(static_cast<SessionBadge*>(user_data));
}

static gboolean tick_cb(gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  if (self->window == nullptr) {
    self->timer_id = 0;
    return G_SOURCE_REMOVE;
  }
  // Re-assert "always on top" and the corner placement every second; some
  // window managers drop the hint when another window goes full screen.
  gtk_window_set_keep_above(GTK_WINDOW(self->window), TRUE);
  GdkWindow* gdk_window = gtk_widget_get_window(self->window);
  if (gdk_window != nullptr) {
    gdk_window_raise(gdk_window);
  }
  reposition(self);
  gtk_widget_queue_draw(self->window);
  return G_SOURCE_CONTINUE;
}

static gboolean button_press_cb(GtkWidget* widget, GdkEventButton* event,
                                gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  if (event->button == 1 && point_in_rect(self->button_rect, event->x, event->y)) {
    self->pressed_button = TRUE;
    gtk_widget_queue_draw(widget);
  }
  return TRUE;
}

static gboolean button_release_cb(GtkWidget* widget, GdkEventButton* event,
                                  gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  const gboolean was_pressed = self->pressed_button;
  self->pressed_button = FALSE;
  gtk_widget_queue_draw(widget);
  if (event->button == 1 && was_pressed &&
      point_in_rect(self->button_rect, event->x, event->y)) {
    // Ends the sessions (core's job); the badge itself is dismissed by core
    // once no session remains, never by this click.
    fl_method_channel_invoke_method(self->channel, "stopPressed", nullptr,
                                    nullptr, nullptr, nullptr);
  }
  return TRUE;
}

static gboolean motion_cb(GtkWidget* widget, GdkEventMotion* event,
                          gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  const gboolean hover =
      point_in_rect(self->button_rect, event->x, event->y) ? TRUE : FALSE;
  if (hover != self->hover_button) {
    self->hover_button = hover;
    gtk_widget_queue_draw(widget);
  }
  return TRUE;
}

static gboolean leave_cb(GtkWidget* widget, GdkEventCrossing* event,
                         gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  self->hover_button = FALSE;
  self->pressed_button = FALSE;
  gtk_widget_queue_draw(widget);
  return TRUE;
}

static gboolean delete_cb(GtkWidget* widget, GdkEvent* event,
                          gpointer user_data) {
  return TRUE;  // the badge cannot be closed by the window manager
}

static void create_window(SessionBadge* self) {
  GtkWidget* window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  GtkWindow* gtk_win = GTK_WINDOW(window);
  gtk_window_set_title(gtk_win, "Thelxis session badge");
  gtk_window_set_decorated(gtk_win, FALSE);
  gtk_window_set_resizable(gtk_win, FALSE);
  gtk_window_set_keep_above(gtk_win, TRUE);
  gtk_window_set_skip_taskbar_hint(gtk_win, TRUE);
  gtk_window_set_skip_pager_hint(gtk_win, TRUE);
  gtk_window_set_type_hint(gtk_win, GDK_WINDOW_TYPE_HINT_NOTIFICATION);
  gtk_window_set_accept_focus(gtk_win, FALSE);
  gtk_window_set_focus_on_map(gtk_win, FALSE);
  gtk_window_stick(gtk_win);
  gtk_window_set_default_size(gtk_win, kWidth, kHeight);
  gtk_widget_set_size_request(window, kWidth, kHeight);

  gtk_widget_set_app_paintable(window, TRUE);
  GdkScreen* screen = gtk_widget_get_screen(window);
  GdkVisual* visual = gdk_screen_get_rgba_visual(screen);
  if (visual != nullptr) {
    gtk_widget_set_visual(window, visual);
  }

  gtk_widget_add_events(window, GDK_BUTTON_PRESS_MASK | GDK_BUTTON_RELEASE_MASK |
                                    GDK_POINTER_MOTION_MASK |
                                    GDK_LEAVE_NOTIFY_MASK);
  g_signal_connect(window, "draw", G_CALLBACK(draw_cb), self);
  g_signal_connect(window, "button-press-event", G_CALLBACK(button_press_cb),
                   self);
  g_signal_connect(window, "button-release-event",
                   G_CALLBACK(button_release_cb), self);
  g_signal_connect(window, "motion-notify-event", G_CALLBACK(motion_cb), self);
  g_signal_connect(window, "leave-notify-event", G_CALLBACK(leave_cb), self);
  g_signal_connect(window, "delete-event", G_CALLBACK(delete_cb), self);
  g_signal_connect(screen, "monitors-changed", G_CALLBACK(screen_changed_cb),
                   self);
  g_signal_connect(screen, "size-changed", G_CALLBACK(screen_changed_cb), self);

  self->window = window;
  gtk_widget_show(window);
}

static void destroy_window(SessionBadge* self) {
  if (self->timer_id != 0) {
    g_source_remove(self->timer_id);
    self->timer_id = 0;
  }
  if (self->window != nullptr) {
    GdkScreen* screen = gtk_widget_get_screen(self->window);
    g_signal_handlers_disconnect_by_data(screen, self);
    GtkWidget* window = self->window;
    self->window = nullptr;
    gtk_widget_destroy(window);
  }
  self->hover_button = FALSE;
  self->pressed_button = FALSE;
}

// ---- channel ---------------------------------------------------------------

static const gchar* map_string(FlValue* map, const char* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(value);
  }
  return nullptr;
}

static void badge_show(SessionBadge* self, FlValue* args) {
  const gchar* label = map_string(args, "label");
  const gchar* stop_label = map_string(args, "stopLabel");
  g_free(self->label);
  g_free(self->stop_label);
  self->label = g_strdup(label != nullptr ? label : "");
  self->stop_label = g_strdup(stop_label != nullptr ? stop_label : "");

  FlValue* since = fl_value_lookup_string(args, "sinceMs");
  if (since != nullptr && fl_value_get_type(since) == FL_VALUE_TYPE_INT) {
    self->since_ms = fl_value_get_int(since);
  } else {
    self->since_ms = g_get_real_time() / 1000;
  }
  FlValue* control = fl_value_lookup_string(args, "controlActive");
  self->control_active =
      (control != nullptr && fl_value_get_type(control) == FL_VALUE_TYPE_BOOL &&
       fl_value_get_bool(control))
          ? TRUE
          : FALSE;

  if (self->window == nullptr) {
    create_window(self);
  }
  if (self->timer_id == 0) {
    self->timer_id = g_timeout_add_seconds(1, tick_cb, self);
  }
  reposition(self);
  gtk_widget_queue_draw(self->window);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  SessionBadge* self = static_cast<SessionBadge*>(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "show") == 0) {
    if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad_args", "show expects a map", nullptr));
    } else {
      badge_show(self, args);
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (strcmp(method, "dismiss") == 0) {
    destroy_window(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to send badge response: %s", error->message);
  }
}

SessionBadge* session_badge_new(FlBinaryMessenger* messenger) {
  SessionBadge* self = new SessionBadge();
  self->icon = load_icon();
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(messenger, "io.thelxis/badge",
                                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb, self,
                                            nullptr);
  return self;
}

void session_badge_free(SessionBadge* self) {
  if (self == nullptr) {
    return;
  }
  destroy_window(self);
  // The messenger holds its own reference to the channel; unregister the
  // handler so it can never run with a dangling |self|.
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&self->channel);
  g_clear_object(&self->icon);
  g_free(self->label);
  g_free(self->stop_label);
  delete self;
}
