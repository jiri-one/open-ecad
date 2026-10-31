#include "../pointer_warp.cc"

#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
  gtk_init(&argc, &argv);
  GdkDisplay* display = gdk_display_get_default();
  if (!GDK_IS_X11_DISPLAY(display)) return 77;
  GtkWidget* widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(widget), 400, 300);
  gtk_window_move(GTK_WINDOW(widget), 120, 100);
  gtk_widget_show_all(widget);
  while (gtk_events_pending()) gtk_main_iteration();
  GdkWindow* window = gtk_widget_get_window(widget);
  GdkScreen* screen = gtk_widget_get_screen(widget);
  const int scale = gtk_widget_get_scale_factor(widget);
  int origin_x, origin_y;
  gdk_window_get_origin(window, &origin_x, &origin_y);
  const int x = origin_x + 60;
  const int y = origin_y + 60;
  int checked = 0;
  auto check = [&](bool expected) {
    checked++;
    if (target_belongs_to_window(display, screen, window, x, y, scale) != expected) {
      std::fprintf(stderr, "Target ownership case %d failed\n", checked);
      std::exit(1);
    }
  };
  check(true);
  Display* other = XOpenDisplay(nullptr);
  if (other == nullptr) return 1;
  const Window root = DefaultRootWindow(other);
  XSetWindowAttributes attributes = {};
  attributes.override_redirect = True;
  const Window overlay = XCreateWindow(other, root, (x - 10) * scale,
      (y - 10) * scale, 40 * scale, 40 * scale, 0, CopyFromParent,
      InputOutput, CopyFromParent, CWOverrideRedirect, &attributes);
  XMapRaised(other, overlay);
  XSync(other, False);
  check(false);
  XUnmapWindow(other, overlay);
  XSync(other, False);
  check(true);
  const Window input = XCreateWindow(other, root, (x - 10) * scale,
      (y - 10) * scale, 40 * scale, 40 * scale, 0, 0,
      InputOnly, CopyFromParent, CWOverrideRedirect, &attributes);
  XMapRaised(other, input);
  XSync(other, False);
  check(false);
  XDestroyWindow(other, input);
  XDestroyWindow(other, overlay);
  XSync(other, False);
  check(true);
  XCloseDisplay(other);

  Display* native = gdk_x11_display_get_xdisplay(display);
  const Window own = gdk_x11_window_get_xid(window);
  const Window frame = XCreateSimpleWindow(native, DefaultRootWindow(native),
      (origin_x - 10) * scale, (origin_y - 20) * scale,
      440 * scale, 360 * scale, 0, 0, 0);
  XReparentWindow(native, own, frame, 10 * scale, 20 * scale);
  XMapWindow(native, own);
  XMapRaised(native, frame);
  XSync(native, False);
  check(true);
  XReparentWindow(native, own, DefaultRootWindow(native), origin_x * scale, origin_y * scale);
  XDestroyWindow(native, frame);
  XSync(native, False);
  gtk_widget_destroy(widget);
  std::printf("PASS: %d target ownership cases at GTK scale %d\n", checked, scale);
  return 0;
}
