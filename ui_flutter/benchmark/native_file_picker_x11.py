"""Select a disposable fixture path in this test's real GTK native file chooser.

Xvfb verification only. Never types a key/password, and never targets terminals.
"""
import ctypes as c
from pathlib import Path
import sys
import time

mode, filename = sys.argv[1:]
target = Path(filename).absolute()
if mode not in {"open", "save"} or not str(target).startswith("/tmp/hspterm-vault-ui-"):
    raise SystemExit("Only disposable UI fixture paths are allowed")
title = {"open": "Open File", "save": "Save File"}[mode]
x = c.CDLL("libX11.so.6")
test = c.CDLL("libXtst.so.6")
x.XOpenDisplay.restype = c.c_void_p
x.XDefaultRootWindow.argtypes = [c.c_void_p]
x.XDefaultRootWindow.restype = c.c_ulong
x.XQueryTree.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_ulong), c.POINTER(c.c_ulong), c.POINTER(c.POINTER(c.c_ulong)), c.POINTER(c.c_uint)]
x.XFetchName.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(c.c_void_p)]
x.XFree.argtypes = [c.c_void_p]
x.XSetInputFocus.argtypes = [c.c_void_p, c.c_ulong, c.c_int, c.c_ulong]
x.XRaiseWindow.argtypes = [c.c_void_p, c.c_ulong]
x.XStringToKeysym.argtypes = [c.c_char_p]
x.XStringToKeysym.restype = c.c_ulong
x.XKeysymToKeycode.argtypes = [c.c_void_p, c.c_ulong]
x.XKeysymToKeycode.restype = c.c_uint
x.XKeycodeToKeysym.argtypes = [c.c_void_p, c.c_uint, c.c_int]
x.XKeycodeToKeysym.restype = c.c_ulong
x.XSync.argtypes = [c.c_void_p, c.c_int]
x.XCloseDisplay.argtypes = [c.c_void_p]
class Attributes(c.Structure):
    _fields_ = [("x", c.c_int), ("y", c.c_int), ("width", c.c_int), ("height", c.c_int),
                ("border", c.c_int), ("depth", c.c_int), ("visual", c.c_void_p),
                ("root", c.c_ulong), ("window_class", c.c_int), ("bit_gravity", c.c_int),
                ("win_gravity", c.c_int), ("backing_store", c.c_int), ("backing_planes", c.c_ulong),
                ("backing_pixel", c.c_ulong), ("save_under", c.c_int), ("colormap", c.c_ulong),
                ("map_installed", c.c_int), ("map_state", c.c_int), ("all_masks", c.c_long),
                ("your_mask", c.c_long), ("propagate_mask", c.c_long), ("override", c.c_int),
                ("screen", c.c_void_p)]
x.XGetWindowAttributes.argtypes = [c.c_void_p, c.c_ulong, c.POINTER(Attributes)]
ErrorHandler = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_void_p)
ignore_destroyed_window = ErrorHandler(lambda *_: 0)
x.XSetErrorHandler.argtypes = [ErrorHandler]
x.XSetErrorHandler(ignore_destroyed_window)
test.XTestFakeKeyEvent.argtypes = [c.c_void_p, c.c_uint, c.c_int, c.c_ulong]
display = x.XOpenDisplay(None)
if not display:
    raise SystemExit("The fixture needs its own Xvfb DISPLAY")


def chooser(window):
    name = c.c_void_p()
    if x.XFetchName(display, window, c.byref(name)) and name:
        matches = c.string_at(name).decode("utf-8", "replace") == title
        x.XFree(name)
        attributes = Attributes()
        if matches and x.XGetWindowAttributes(display, window, c.byref(attributes)) and attributes.map_state == 2:
            return window
    root, parent, children, length = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if not x.XQueryTree(display, window, c.byref(root), c.byref(parent), c.byref(children), c.byref(length)):
        return None
    ids = list(children[:length.value])
    if children:
        x.XFree(children)
    for child in ids:
        found = chooser(child)
        if found:
            return found
    return None


def code(name):
    symbol = ord(name) if len(name) == 1 else x.XStringToKeysym(name.encode("ascii"))
    value = x.XKeysymToKeycode(display, symbol)
    if not value:
        raise RuntimeError("Fixture keymap does not contain the requested key")
    return value


def key(value, down):
    test.XTestFakeKeyEvent(display, value, int(down), 0)


def chord(modifier, letter):
    first, second = code(modifier), code(letter)
    key(first, True)
    key(second, True)
    key(second, False)
    key(first, False)
    x.XSync(display, 0)


success = False
window = None
try:
    deadline = time.monotonic() + 15
    while window is None:
        window = chooser(x.XDefaultRootWindow(display))
        if time.monotonic() > deadline:
            raise RuntimeError("Native file chooser was not found")
        time.sleep(.05)
    x.XRaiseWindow(display, window)
    x.XSetInputFocus(display, window, 2, 0)
    chord("Control_L", "l")
    time.sleep(.35)
    chord("Control_L", "a")
    time.sleep(.1)
    for character in str(target):
        value = code(character)
        shifted = x.XKeycodeToKeysym(display, value, 0) != ord(character)
        if shifted:
            key(code("Shift_L"), True)
        key(value, True)
        key(value, False)
        if shifted:
            key(code("Shift_L"), False)
        x.XSync(display, 0)
        time.sleep(.005)
    # A directory navigation can consume the first Enter. Only repeat while
    # the original file chooser still exists, never into the Flutter window.
    accept_deadline = time.monotonic() + 10
    while time.monotonic() < accept_deadline:
        current = chooser(x.XDefaultRootWindow(display))
        if current != window:
            success = True
            break
        x.XSetInputFocus(display, window, 2, 0)
        value = code("Return")
        key(value, True)
        key(value, False)
        x.XSync(display, 0)
        time.sleep(.5)
    success = success or chooser(x.XDefaultRootWindow(display)) != window
    if not success:
        raise RuntimeError("Native file chooser did not accept the fixture path")
finally:
    if not success and window and chooser(x.XDefaultRootWindow(display)) == window:
        key(code("Escape"), True)
        key(code("Escape"), False)
        x.XSync(display, 0)
    x.XCloseDisplay(display)
