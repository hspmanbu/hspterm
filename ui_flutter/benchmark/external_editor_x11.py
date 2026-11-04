"""Edit/save/close only the disposable Mousepad opened by the GTK SSH test.

Requires a private Xvfb/D-Bus session. Does not target terminals or user files.
"""
import ctypes as c
import os
from pathlib import Path
import re
import subprocess
import sys
import time

mode, filename = sys.argv[1:]
target = Path(filename).absolute()
if mode not in {"edit", "close"} or not re.fullmatch(
    r"/tmp/hspterm-flutter-sshd-[^/]+/external work 中文/hspterm-editing-v1/edit-[0-9a-f]{32}/document.txt",
    str(target),
):
    raise SystemExit("Only the disposable external editor fixture is allowed")
if not os.environ.get("DISPLAY") or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
    raise SystemExit("Private Xvfb and D-Bus required")

x = c.CDLL("libX11.so.6")
xt = c.CDLL("libXtst.so.6")
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XInternAtom.argtypes = [c.c_void_p, c.c_char_p, c.c_int]
x.XInternAtom.restype = c.c_ulong
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XGetWindowProperty.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_long, c.c_long, c.c_int, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_int), c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.c_void_p)]
x.XFree.argtypes = [c.c_void_p]
class WindowAttributes(c.Structure):
    _fields_ = [(name, kind) for name, kind in [
        ("x", c.c_int), ("y", c.c_int), ("width", c.c_int), ("height", c.c_int),
        ("border_width", c.c_int), ("depth", c.c_int), ("visual", c.c_void_p),
        ("root", c.c_ulong), ("window_class", c.c_int), ("bit_gravity", c.c_int),
        ("win_gravity", c.c_int), ("backing_store", c.c_int),
        ("backing_planes", c.c_ulong), ("backing_pixel", c.c_ulong),
        ("save_under", c.c_int), ("colormap", c.c_ulong),
        ("map_installed", c.c_int), ("map_state", c.c_int),
        ("all_event_masks", c.c_long), ("your_event_mask", c.c_long),
        ("do_not_propagate_mask", c.c_long), ("override_redirect", c.c_int),
        ("screen", c.c_void_p),
    ]]
x.XGetWindowAttributes.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(WindowAttributes)]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XGetInputFocus.argtypes = [c.c_void_p, c.POINTER(c.c_ulong), c.POINTER(c.c_int)]
x.XRaiseWindow.argtypes = [c.c_void_p, c.c_ulong]
x.XStringToKeysym.argtypes = [c.c_char_p]
x.XStringToKeysym.restype = c.c_ulong
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
x.XSync.argtypes = [c.c_void_p, c.c_int]
x.XCloseDisplay.argtypes = [c.c_void_p]
x.XTranslateCoordinates.argtypes = [c.c_void_p, c.c_ulong, c.c_ulong, c.c_int, c.c_int, c.POINTER(c.c_int), c.POINTER(c.c_int), c.POINTER(c.c_ulong)]
xt.XTestFakeMotionEvent.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_ulong]
xt.XTestFakeButtonEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
xt.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
Handler = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
ignore_destroyed = Handler(lambda *_: 0)
x.XSetErrorHandler.argtypes = [Handler]
x.XSetErrorHandler(ignore_destroyed)
display = x.XOpenDisplay(None)
if not display:
    raise SystemExit("X11 unavailable")
atom = x.XInternAtom(display, b"_NET_WM_PID", 0)


def fixture_pid(pid):
    try:
        process = Path(f"/proc/{pid}")
        return (process.stat().st_uid == os.getuid()
                and (process / "exe").resolve() == Path("/usr/bin/mousepad").resolve()
                and str(target).encode() in (process / "cmdline").read_bytes().split(b"\0"))
    except (OSError, RuntimeError):
        return False


def find(window):
    actual, count, after = c.c_ulong(), c.c_ulong(), c.c_ulong()
    fmt, value = c.c_int(), c.c_void_p()
    x.XGetWindowProperty(display, window, atom, 0, 1, 0, 6, c.byref(actual), c.byref(fmt), c.byref(count), c.byref(after), c.byref(value))
    if value:
        matches = fmt.value == 32 and count.value == 1 and fixture_pid(c.cast(value, c.POINTER(c.c_ulong))[0])
        x.XFree(value)
        if matches:
            attributes = WindowAttributes()
            if (x.XGetWindowAttributes(display, window, c.byref(attributes))
                    and attributes.map_state == 2
                    and attributes.width >= 320 and attributes.height >= 200):
                return window
    root, parent, children, length = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if not x.XQueryTree(display, window, c.byref(root), c.byref(parent), c.byref(children), c.byref(length)):
        return None
    ids = list(children[:length.value])
    if children:
        x.XFree(children)
    for child in ids:
        found = find(child)
        if found:
            return found
    return None


def chord(letter):
    control = x.XKeysymToKeycode(display, x.XStringToKeysym(b"Control_L"))
    key = x.XKeysymToKeycode(display, ord(letter))
    for code, down in [(control, 1), (key, 1), (key, 0), (control, 0)]:
        xt.XTestFakeKeyEvent(display, code, down, 0)
    x.XSync(display, 0)


try:
    root = x.XDefaultRootWindow(display)
    deadline = time.monotonic() + 15
    window = find(root)
    while window is None and time.monotonic() < deadline:
        time.sleep(.05)
        window = find(root)
    if window is None:
        if mode == "edit":
            raise RuntimeError("Fixture Mousepad window not found")
        sys.exit(0)
    x.XRaiseWindow(display, window)
    x.XSetInputFocus(display, window, 2, 0)
    if mode == "edit":
        # Activating the toplevel does not focus the text widget when a large
        # document finishes loading asynchronously. Click only the verified
        # disposable editor's document area before sending its editing keys.
        px, py, child = c.c_int(), c.c_int(), c.c_ulong()
        if not x.XTranslateCoordinates(display, window, root, 150, 150, c.byref(px), c.byref(py), c.byref(child)):
            raise RuntimeError("Fixture document coordinates unavailable")
        xt.XTestFakeMotionEvent(display, -1, px.value, py.value, 0)
        xt.XTestFakeButtonEvent(display, 1, 1, 0)
        xt.XTestFakeButtonEvent(display, 1, 0, 0)
        x.XSync(display, 0)
        time.sleep(.2)
        focused, revert = c.c_ulong(), c.c_int()
        x.XGetInputFocus(display, c.byref(focused), c.byref(revert))
        cursor = focused.value
        for _ in range(32):
            if cursor == window:
                break
            parent, found_root = c.c_ulong(), c.c_ulong()
            children, length = c.POINTER(c.c_ulong)(), c.c_uint()
            if not x.XQueryTree(display, cursor, c.byref(found_root), c.byref(parent), c.byref(children), c.byref(length)):
                raise RuntimeError("Fixture input focus disappeared")
            if children:
                x.XFree(children)
            if parent.value in {0, cursor}:
                raise RuntimeError("Fixture document did not receive input focus; no keys sent")
            cursor = parent.value
        else:
            raise RuntimeError("Fixture focus ancestry invalid; no keys sent")
        # X clipboard is isolated to this test display. Only synthetic text.
        content = "Mousepad external 中文 é 😀\nsecond saved line\n"
        subprocess.run(["xclip", "-selection", "clipboard"], input=content.encode(),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        chord("a")
        chord("v")
        time.sleep(.3)
        chord("s")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if target.read_text() == content:
                break
            time.sleep(.05)
        else:
            raise RuntimeError("Real editor Save did not write the expected fixture")
    chord("q")
    deadline = time.monotonic() + 10
    while find(root) is not None and time.monotonic() < deadline:
        time.sleep(.05)
    if find(root) is not None:
        raise RuntimeError("Fixture editor did not close; work files must be retained")
finally:
    x.XCloseDisplay(display)
