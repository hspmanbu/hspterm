"""Linux verification helper: resize this benchmark's own GTK window via X11.

Not application code and not a Windows/Android window implementation.
"""
import ctypes as c
import os
import sys

closing = len(sys.argv) == 3 and sys.argv[2] == "--close"
unfocus = len(sys.argv) == 3 and sys.argv[2] == "--unfocus"
file_menu = len(sys.argv) == 5 and sys.argv[2] == "--sftp-menu"
if closing or unfocus:
    pid = int(sys.argv[1])
    if unfocus:
        from pathlib import Path
        bundle = Path(__file__).resolve().parents[1] / 'build/linux/x64'
        own = Path(f'/proc/{pid}/exe').resolve()
        if own not in {bundle / mode / 'bundle/hspterm' for mode in ('debug', 'release')}:
            raise SystemExit('Unfocus sampling requires this project’s built workbench')
elif file_menu:
    pid, click_x, click_y = int(sys.argv[1]), int(sys.argv[3]), int(sys.argv[4])
    from pathlib import Path
    expected = Path(__file__).resolve().parents[1] / 'build/linux/x64/debug/bundle/hspterm'
    if Path(f'/proc/{pid}/exe').resolve() != expected or not (0 < click_x < 380 and 160 < click_y < 440):
        raise SystemExit('SFTP fixture clicks require the test runner and its file-list area')
else:
    pid, width, height = map(int, sys.argv[1:])
if pid <= 1 or os.stat(f"/proc/{pid}").st_uid != os.getuid():
    raise SystemExit("Benchmark PID must belong to the current user")
x = c.CDLL("libX11.so.6")
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XFree.argtypes = [c.c_void_p]
x.XGetGeometry.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint), c.POINTER(c.c_uint)]
x.XResizeWindow.argtypes = [c.c_void_p, c.c_ulong, c.c_uint, c.c_uint]
x.XSync.argtypes = [c.c_void_p, c.c_int]
x.XCloseDisplay.argtypes = [c.c_void_p]
display = x.XOpenDisplay(None)
if not display:
    raise SystemExit("X11 DISPLAY required")
atom = x.XInternAtom(display, b"_NET_WM_PID", 0)


def find(window):
    actual, count, after = c.c_ulong(), c.c_ulong(), c.c_ulong()
    fmt, value = c.c_int(), c.c_void_p()
    x.XGetWindowProperty(display, window, atom, 0, 1, 0, 6, c.byref(actual), c.byref(fmt), c.byref(count), c.byref(after), c.byref(value))
    if value:
        match = fmt.value == 32 and count.value == 1 and c.cast(value, c.POINTER(c.c_ulong))[0] == pid
        x.XFree(value)
        if match:
            root, px, py, w, h, border, depth = c.c_ulong(), c.c_int(), c.c_int(), c.c_uint(), c.c_uint(), c.c_uint(), c.c_uint()
            if x.XGetGeometry(display, window, c.byref(root), c.byref(px), c.byref(py), c.byref(w), c.byref(h), c.byref(border), c.byref(depth)) and w.value >= 300 and h.value >= 200:
                return window
    root, parent, children, length = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if not x.XQueryTree(display, window, c.byref(root), c.byref(parent), c.byref(children), c.byref(length)):
        return None
    ids = list(children[:length.value])
    if children:
        x.XFree(children)
    for child in ids:
        match = find(child)
        if match:
            return match
    return None


try:
    window = find(x.XDefaultRootWindow(display))
    if window is None:
        raise SystemExit("Benchmark GTK window was not found")
    if unfocus:
        # Used only in the disposable Xvfb benchmark session. FocusOut pauses
        # the password caret, separating actual idle from necessary animation.
        x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
        x.XSetInputFocus(display, x.XDefaultRootWindow(display), 2, 0)
    elif file_menu:
        xt = c.CDLL('libXtst.so.6')
        xt.XTestFakeMotionEvent.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_ulong]
        xt.XTestFakeButtonEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
        x.XTranslateCoordinates.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_ulong)]
        x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
        px, py, child = c.c_int(), c.c_int(), c.c_ulong()
        if not x.XTranslateCoordinates(display, window, x.XDefaultRootWindow(display), click_x, click_y, c.byref(px), c.byref(py), c.byref(child)):
            raise SystemExit('Fixture window coordinates unavailable')
        x.XSetInputFocus(display, window, 2, 0)
        xt.XTestFakeMotionEvent(display, -1, px.value, py.value, 0)
        xt.XTestFakeButtonEvent(display, 3, 1, 0)
        xt.XTestFakeButtonEvent(display, 3, 0, 0)
    elif closing:
        class Data(c.Union):
            _fields_ = [("longs", c.c_long * 5), ("bytes", c.c_char * 20)]
        class Message(c.Structure):
            _fields_ = [("type", c.c_int), ("serial", c.c_ulong), ("send_event", c.c_int), ("display", c.c_void_p), ("window", c.c_ulong), ("message_type", c.c_ulong), ("format", c.c_int), ("data", Data)]
        class Event(c.Union):
            _fields_ = [("message", Message), ("padding", c.c_long * 24)]
        event = Event()
        event.message.type = 33
        event.message.display = display
        event.message.window = window
        event.message.message_type = x.XInternAtom(display, b"WM_PROTOCOLS", 0)
        event.message.format = 32
        event.message.data.longs[0] = x.XInternAtom(display, b"WM_DELETE_WINDOW", 0)
        x.XSendEvent.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_long, c.POINTER(Event)]
        if not x.XSendEvent(display, window, 0, 0, c.byref(event)):
            raise SystemExit("Failed to send benchmark close request")
    else:
        x.XResizeWindow(display, window, width, height)
    x.XSync(display, 0)
finally:
    x.XCloseDisplay(display)
