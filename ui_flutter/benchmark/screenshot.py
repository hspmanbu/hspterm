"""Capture the workbench window to PNG via XGetImage (no external deps)."""
import ctypes as c, struct, sys, zlib

pid = int(sys.argv[1]); out = sys.argv[2]
x = c.CDLL("libX11.so.6")
display = x.XOpenDisplay(None)
if not display:
    raise SystemExit('no display')
root = x.XDefaultRootWindow(display)
atom = x.XInternAtom(display, b'_NET_WM_PID', False)

def find(window):
    actual, count, after = c.c_ulong(), c.c_ulong(), c.c_ulong()
    fmt, value = c.c_int(), c.c_void_p()
    x.XGetWindowProperty(display, window, atom, 0, 1, 0, 6, c.byref(actual), c.byref(fmt), c.byref(count), c.byref(after), c.byref(value))
    if value:
        match = fmt.value == 32 and count.value == 1 and c.cast(value, c.POINTER(c.c_ulong))[0] == pid
        x.XFree(value)
        if match:
            return window
    _, _, children, length = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
    if not x.XQueryTree(display, window, c.byref(_), c.byref(_), c.byref(children), c.byref(length)):
        return None
    ids = list(children[:length.value])
    if children:
        x.XFree(children)
    for child in ids:
        if find(child):
            return find(child)
    return None

win = find(root)
if not win:
    raise SystemExit('window not found')
class XGA(c.Structure):
    _fields_ = [('x', c.c_int), ('y', c.c_int), ('width', c.c_int), ('height', c.c_int), ('border', c.c_int), ('depth', c.c_int), ('visual', c.c_void_p), ('root', c.c_ulong), ('class', c.c_int), ('bit_gravity', c.c_int), ('win_gravity', c.c_int), ('backing', c.c_int), ('save_under', c.c_int), ('colormap', c.c_ulong), ('map_installed', c.c_uint), ('map_state', c.c_uint), ('all_event', c.c_long), ('your_event', c.c_long), ('prop', c.c_long), ('do_not_prop', c.c_long)]
ga = XGA()
x.XGetWindowAttributes(display, win, c.byref(ga))
w, h = ga.width, ga.height
# Capture from the root at the window region: the Flutter surface composites
# onto the root while the window visual can mismatch under Xvfb (BadMatch).
rr = c.c_int(); rx = c.c_int(); child = c.c_ulong()
x.XTranslateCoordinates(display, win, root, 0, 0, c.byref(rx), c.byref(rr), c.byref(child))
image = x.XGetImage(display, root, rx.value, rr.value, w, h, c.c_ulong(0xFFFFFFFF), 2)

if not image:
    raise SystemExit('XGetImage failed')
class XImage(c.Structure):
    _fields_ = [('width', c.c_int), ('height', c.c_int), ('xoffset', c.c_int), ('format', c.c_int), ('data', c.c_void_p), ('byte_order', c.c_int), ('bitmap_unit', c.c_int), ('bitmap_bit_order', c.c_int), ('depth', c.c_int), ('bytes_per_line', c.c_int), ('bits_per_pixel', c.c_int), ('red_mask', c.c_ulong), ('green_mask', c.c_ulong), ('blue_mask', c.c_ulong)]
img = c.cast(image, c.POINTER(XImage)).contents
buf = c.string_at(img.data, img.bytes_per_line * img.height)
# bgra -> rgb rows
rows = []
for yy in range(img.height):
    line = buf[yy*img.bytes_per_line:(yy+1)*img.bytes_per_line]
    row = bytearray()
    for xx in range(img.width):
        b, g, rr = line[xx*4+0], line[xx*4+1], line[xx*4+2]
        row += bytes((rr, g, b))
    rows.append(bytes(row))
raw = b''.join(rows)

def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)

png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', img.width, img.height, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b''.join(b'\x00' + r for r in rows), 6))
png += chunk(b'IEND', b'')
open(out, 'wb').write(png)
x.XDestroyImage(image)
x.XCloseDisplay(display)
print(f'saved {out} {img.width}x{img.height}')
