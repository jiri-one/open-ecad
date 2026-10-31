#include "pointer_warp.h"

#include <cmath>
#include <limits>

#if defined(GDK_WINDOWING_X11) && defined(ECAD_X11_PREFLIGHT)
#include <gdk/gdkx.h>
#endif

namespace {

#if defined(GDK_WINDOWING_X11) && defined(ECAD_X11_PREFLIGHT)
bool target_belongs_to_window(GdkDisplay* display, GdkScreen* screen,
                              GdkWindow* window, int x, int y, int scale) {
  const double physical_x = static_cast<double>(x) * scale;
  const double physical_y = static_cast<double>(y) * scale;
  if (physical_x < std::numeric_limits<int>::min() ||
      physical_x > std::numeric_limits<int>::max() ||
      physical_y < std::numeric_limits<int>::min() ||
      physical_y > std::numeric_limits<int>::max()) {
    return false;
  }
  Display* xdisplay = gdk_x11_display_get_xdisplay(display);
  const Window root = gdk_x11_window_get_xid(gdk_screen_get_root_window(screen));
  const Window own = gdk_x11_window_get_xid(window);
  Window current = root;
  bool belongs = false;
  gdk_x11_display_error_trap_push(display);
  // Follow the topmost mapped child at the target, including WM frames.
  for (int depth = 0; depth < 64; depth++) {
    if (current == own) {
      belongs = true;
      break;
    }
    int local_x, local_y;
    Window child = None;
    if (!XTranslateCoordinates(xdisplay, root, current,
                               static_cast<int>(physical_x),
                               static_cast<int>(physical_y), &local_x, &local_y,
                               &child) || child == None || child == current) {
      break;
    }
    current = child;
  }
  const int error = gdk_x11_display_error_trap_pop(display);
  return belongs && error == 0;
}

bool read_number(FlValue* args, const char* key, double* result) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) return false;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    *result = fl_value_get_float(value);
  } else if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    *result = fl_value_get_int(value);
  } else {
    return false;
  }
  return std::isfinite(*result);
}
#endif

bool warp_pointer(FlView* view, FlValue* args) {
#if !defined(GDK_WINDOWING_X11) || !defined(ECAD_X11_PREFLIGHT)
  return false;
#else
  if (!g_main_context_is_owner(g_main_context_default()) || args == nullptr ||
      fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return false;
  }
  GtkWidget* widget = GTK_WIDGET(view);
  if (gtk_widget_in_destruction(widget) || !gtk_widget_get_realized(widget) ||
      !gtk_widget_get_mapped(widget) || !gtk_widget_is_sensitive(widget)) {
    return false;
  }
  GdkDisplay* display = gtk_widget_get_display(widget);
  if (!GDK_IS_X11_DISPLAY(display)) return false;
  FlValue* view_id = fl_value_lookup_string(args, "viewId");
  if (view_id == nullptr || fl_value_get_type(view_id) != FL_VALUE_TYPE_INT ||
      fl_value_get_int(view_id) != fl_view_get_id(view)) {
    return false;
  }

  GtkWidget* toplevel = gtk_widget_get_toplevel(widget);
  if (!GTK_IS_WINDOW(toplevel) || gtk_widget_in_destruction(toplevel) ||
      !gtk_widget_get_mapped(toplevel) ||
      !gtk_window_is_active(GTK_WINDOW(toplevel)) ||
      !gtk_widget_has_focus(widget) || gtk_grab_get_current() != nullptr) {
    return false;
  }
  GdkWindow* window = gtk_widget_get_window(toplevel);
  if (window == nullptr || gdk_window_is_destroyed(window) ||
      !gdk_window_is_viewable(window) ||
      (gdk_window_get_state(window) &
       (GDK_WINDOW_STATE_ICONIFIED | GDK_WINDOW_STATE_WITHDRAWN))) {
    return false;
  }
  GList* windows = gtk_window_list_toplevels();
  bool modal = false;
  for (GList* item = windows; item != nullptr; item = item->next) {
    if (item->data != toplevel &&
        gtk_widget_get_visible(GTK_WIDGET(item->data)) &&
        gtk_window_get_modal(GTK_WINDOW(item->data))) {
      modal = true;
    }
  }
  g_list_free(windows);
  if (modal) return false;

  double x, y, dpr, physical_width, physical_height;
  if (!read_number(args, "x", &x) || !read_number(args, "y", &y) ||
      !read_number(args, "devicePixelRatio", &dpr) ||
      !read_number(args, "physicalWidth", &physical_width) ||
      !read_number(args, "physicalHeight", &physical_height)) {
    return false;
  }
  const int scale = gtk_widget_get_scale_factor(widget);
  const int width = gtk_widget_get_allocated_width(widget);
  const int height = gtk_widget_get_allocated_height(widget);
  // Reject stale Flutter metrics during resize or monitor/scale transitions.
  if (scale <= 0 || dpr <= 0 || width <= 0 || height <= 0 ||
      std::abs(dpr - scale) > 0.001 ||
      std::abs(physical_width - static_cast<double>(width) * scale) > 1.0 ||
      std::abs(physical_height - static_cast<double>(height) * scale) > 1.0) {
    return false;
  }
  x = x * dpr / scale;
  y = y * dpr / scale;
  if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x >= width ||
      y >= height) {
    return false;
  }
  const int local_x = static_cast<int>(std::round(x));
  const int local_y = static_cast<int>(std::round(y));
  if (local_x >= width || local_y >= height) return false;

  int offset_x, offset_y, origin_x, origin_y;
  // Widget translation includes GtkHeaderBar/CSD; the GDK origin excludes WM
  // borders.
  if (!gtk_widget_translate_coordinates(widget, toplevel, 0, 0, &offset_x,
                                        &offset_y) ||
      !gdk_window_get_origin(window, &origin_x, &origin_y)) {
    return false;
  }
  const double root_x = static_cast<double>(origin_x) + offset_x + local_x;
  const double root_y = static_cast<double>(origin_y) + offset_y + local_y;
  if (root_x < std::numeric_limits<int>::min() ||
      root_x > std::numeric_limits<int>::max() ||
      root_y < std::numeric_limits<int>::min() ||
      root_y > std::numeric_limits<int>::max()) {
    return false;
  }
  const int target_x = static_cast<int>(root_x);
  const int target_y = static_cast<int>(root_y);
  GdkMonitor* monitor =
      gdk_display_get_monitor_at_point(display, target_x, target_y);
  if (monitor == nullptr) return false;
  GdkRectangle monitor_rect;
  gdk_monitor_get_geometry(monitor, &monitor_rect);
  if (root_x < monitor_rect.x || root_y < monitor_rect.y ||
      root_x >= static_cast<double>(monitor_rect.x) + monitor_rect.width ||
      root_y >= static_cast<double>(monitor_rect.y) + monitor_rect.height) {
    return false;
  }

  GdkSeat* seat = gdk_display_get_default_seat(display);
  GdkDevice* pointer = seat == nullptr ? nullptr : gdk_seat_get_pointer(seat);
  if (pointer == nullptr || gdk_display_device_is_grabbed(display, pointer)) {
    return false;
  }
  GdkModifierType modifiers;
  gdk_window_get_device_position(window, pointer, nullptr, nullptr, &modifiers);
  if (modifiers & (GDK_BUTTON1_MASK | GDK_BUTTON2_MASK | GDK_BUTTON3_MASK |
                   GDK_BUTTON4_MASK | GDK_BUTTON5_MASK)) {
    return false;
  }
  GdkWindow* under_pointer =
      gdk_device_get_window_at_position(pointer, nullptr, nullptr);
  GdkScreen* pointer_screen = nullptr;
  double before_x, before_y;
  gdk_device_get_position_double(pointer, &pointer_screen, &before_x,
                                 &before_y);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  if (under_pointer == nullptr ||
      gdk_window_get_toplevel(under_pointer) != window ||
      pointer_screen != screen || before_x < origin_x + offset_x ||
      before_y < origin_y + offset_y ||
      before_x >= static_cast<double>(origin_x) + offset_x + width ||
      before_y >= static_cast<double>(origin_y) + offset_y + height) {
    return false;
  }

  if (!target_belongs_to_window(display, screen, window, target_x, target_y,
                                scale)) {
    return false;
  }
  gdk_device_warp(pointer, screen, target_x, target_y);
  gdk_display_flush(display);
  // A void warp call can be ignored or confined; a server round trip verifies
  // arrival.
  gdk_display_sync(display);
  double actual_x, actual_y;
  gdk_device_get_position_double(pointer, &pointer_screen, &actual_x,
                                 &actual_y);
  under_pointer = gdk_device_get_window_at_position(pointer, nullptr, nullptr);
  const double tolerance = 1.0 / scale;
  return pointer_screen == screen && under_pointer != nullptr &&
         gdk_window_get_toplevel(under_pointer) == window &&
         gtk_window_is_active(GTK_WINDOW(toplevel)) &&
         std::abs(actual_x - root_x) <= tolerance &&
         std::abs(actual_y - root_y) <= tolerance;
#endif
}

void method_call(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  if (g_strcmp0(fl_method_call_get_name(call), "warp") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autoptr(FlView) view =
      FL_VIEW(g_weak_ref_get(static_cast<GWeakRef*>(data)));
  const bool moved =
      view != nullptr && warp_pointer(view, fl_method_call_get_args(call));
  g_autoptr(FlValue) result = fl_value_new_bool(moved);
  fl_method_call_respond_success(call, result, nullptr);
}

}

void register_pointer_warp(FlView* view) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "open_ecad/pointer_warp", FL_METHOD_CODEC(codec));
  auto* weak_view = new GWeakRef;
  g_weak_ref_init(weak_view, view);
  fl_method_channel_set_method_call_handler(
      channel, method_call, weak_view, [](gpointer data) {
        auto* ref = static_cast<GWeakRef*>(data);
        g_weak_ref_clear(ref);
        delete ref;
      });
  // A destroyed view must not remain callable through its engine's messenger.
  g_signal_connect_data(
      view, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
        fl_method_channel_set_method_call_handler(FL_METHOD_CHANNEL(data),
                                                  nullptr, nullptr, nullptr);
      }),
      g_object_ref(channel),
      +[](gpointer data, GClosure*) { g_object_unref(data); },
      G_CONNECT_DEFAULT);
}
