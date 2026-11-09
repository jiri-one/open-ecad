#include "system_typography.h"

namespace {

FlValue* read_font(GtkSettings* settings) {
  g_autoptr(FlValue) result = fl_value_new_map();
  g_autofree gchar* name = nullptr;
  g_object_get(settings, "gtk-font-name", &name, nullptr);
  if (name == nullptr || *name == '\0') return g_steal_pointer(&result);

  g_autoptr(PangoFontDescription) description =
      pango_font_description_from_string(name);
  const char* family = pango_font_description_get_family(description);
  if (family != nullptr && *family != '\0') {
    fl_value_set_string_take(result, "fontFamily", fl_value_new_string(family));
  }

  const double size =
      static_cast<double>(pango_font_description_get_size(description)) /
      PANGO_SCALE;
  if (size > 0) {
    const bool absolute = pango_font_description_get_size_is_absolute(description);
    const double logical_size =
        absolute ? size : size * 96.0 / 72.0;
    fl_value_set_string_take(result, "fontSize",
                             fl_value_new_float(logical_size));
    GdkScreen* screen = gdk_screen_get_default();
    const double dpi = screen == nullptr ? 96.0 : gdk_screen_get_resolution(screen);
    fl_value_set_string_take(result, "fontScale",
                             fl_value_new_float(absolute || dpi <= 0 ? 1.0 : dpi / 96.0));
  }
  return g_steal_pointer(&result);
}

void method_call(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  if (g_strcmp0(fl_method_call_get_name(call), "getFont") != 0) {
    fl_method_call_respond_not_implemented(call, nullptr);
    return;
  }
  g_autoptr(FlValue) result = read_font(GTK_SETTINGS(data));
  fl_method_call_respond_success(call, result, nullptr);
}

void font_changed(GObject*, GParamSpec*, gpointer data) {
  fl_method_channel_invoke_method(FL_METHOD_CHANNEL(data), "fontChanged",
                                  nullptr, nullptr, nullptr, nullptr);
}

struct TypographyBridge {
  GtkSettings* settings;
  GdkScreen* screen;
  FlMethodChannel* channel;
  gulong changed_handler;
  gulong dpi_handler;
  gulong resolution_handler;

  void stop() {
    if (settings != nullptr) {
      g_signal_handler_disconnect(settings, changed_handler);
      g_signal_handler_disconnect(settings, dpi_handler);
    }
    if (screen != nullptr) {
      g_signal_handler_disconnect(screen, resolution_handler);
    }
    if (channel != nullptr) {
      fl_method_channel_set_method_call_handler(channel, nullptr, nullptr,
                                                nullptr);
    }
    g_clear_object(&settings);
    g_clear_object(&screen);
    g_clear_object(&channel);
  }

  ~TypographyBridge() { stop(); }
};

}

void register_system_typography(FlView* view) {
  GtkSettings* settings = gtk_widget_get_settings(GTK_WIDGET(view));
  GdkScreen* screen = gtk_widget_get_screen(GTK_WIDGET(view));
  if (settings == nullptr || screen == nullptr) return;

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "open_ecad/system_typography", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, settings,
                                            nullptr);
  auto* bridge =
      new TypographyBridge{GTK_SETTINGS(g_object_ref(settings)),
                           GDK_SCREEN(g_object_ref(screen)),
                           FL_METHOD_CHANNEL(g_object_ref(channel)),
                           g_signal_connect(settings, "notify::gtk-font-name",
                                            G_CALLBACK(font_changed), channel),
                           g_signal_connect(settings, "notify::gtk-xft-dpi",
                                            G_CALLBACK(font_changed), channel),
                           g_signal_connect(screen, "notify::resolution",
                                            G_CALLBACK(font_changed), channel)};
  g_signal_connect_data(
      view, "destroy", G_CALLBACK(+[](GtkWidget*, gpointer data) {
        static_cast<TypographyBridge*>(data)->stop();
      }),
      bridge,
      +[](gpointer data, GClosure*) {
        delete static_cast<TypographyBridge*>(data);
      },
      G_CONNECT_DEFAULT);
}
