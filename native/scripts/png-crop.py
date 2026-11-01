#!/usr/bin/env python3
"""Cut the region of the display under test out of a full-screen screenshot.

`screencapture -x` writes the whole display space into one PNG, while
`screencapture -R` cannot be used on every host ("could not create image from
rect"). This helper crops the display region with the standard library only:
the PNG decoder is adapted from png-stats.py, extended for 16 bit captures
(a 16 bit capture is quantized to 8 bit), and the cropped result is written
back as an 8 bit RGB PNG that png-stats.py can read.

The region is given in points with the origin at the top left corner of the
display space. It is scaled into pixels of the PNG with the width of the PNG
and the width of the display space; `--minx` is the left edge of the space (a
display left of the leftmost one has negative points). The crop assumes that
the full-screen capture lays every display out at its global position and
scale — true for the side-by-side arrangement this test runs in.

Usage:
  png-crop.py <in.png> <out.png> <x> <y> <w> <h> --space <space-width> --minx <min-x>
  png-crop.py <in.png> --size

`--size` prints {"width": ..., "height": ...} of the PNG without decoding it.
On success the crop prints one JSON object with the measured geometry.
"""

import json
import struct
import sys
import zlib


def read_header(path):
    """Returns the width and height of the PNG without decoding it."""
    with open(path, "rb") as handle:
        head = handle.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)
    width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", head[16:29])
    return {"width": width, "height": height, "bit_depth": depth, "color_type": color}


def decode(path):
    """Returns (width, height, pixels) of a non-interlaced PNG as 8 bit RGB."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)
    position = 8
    idat = b""
    width = height = depth = 0
    color = -1
    interlace = 0
    while position < len(data):
        (length,) = struct.unpack(">I", data[position:position + 4])
        kind = data[position + 4:position + 8]
        chunk = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    if depth not in (8, 16):
        raise ValueError("unsupported PNG bit depth %d in %s" % (depth, path))
    if interlace != 0:
        raise ValueError("interlaced PNG is not supported: %s" % path)
    if color == 3:
        raise ValueError("palette PNG is not supported: %s" % path)
    in_channels = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    samples = depth // 8
    bpp = in_channels * samples
    stride = width * bpp
    raw = zlib.decompress(idat)
    previous = bytearray(stride)
    offset = 0
    pixels = bytearray(height * width * 3)
    for row in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride
        if filter_type == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = previous[i]
                c = previous[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    predictor = a
                elif pb <= pc:
                    predictor = b
                else:
                    predictor = c
                line[i] = (line[i] + predictor) & 0xFF
        previous = line
        target = row * width * 3
        source = 0
        for _ in range(width):
            if color == 2 or color == 6:
                red, green, blue = line[source], line[source + samples], line[source + 2 * samples]
            else:
                red = green = blue = line[source]
            pixels[target] = red
            pixels[target + 1] = green
            pixels[target + 2] = blue
            target += 3
            source += bpp
    return width, height, pixels


def crop(pixels, width, height, crop_x, crop_y, crop_w, crop_h):
    out = bytearray(crop_w * crop_h * 3)
    for row in range(crop_h):
        source = ((crop_y + row) * width + crop_x) * 3
        target = row * crop_w * 3
        out[target:target + crop_w * 3] = pixels[source:source + crop_w * 3]
    return out


def write_png(path, width, height, pixels):
    raw = bytearray()
    stride = width * 3
    for row in range(height):
        raw.append(0)
        raw.extend(pixels[row * stride:(row + 1) * stride])

    def chunk(kind, payload):
        return (struct.pack(">I", len(payload)) + kind + payload +
                struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(bytes(raw))))
        handle.write(chunk(b"IEND", b""))


def main(argv):
    args = list(argv[1:])
    if len(args) == 2 and args[1] == "--size":
        print(json.dumps(read_header(args[0])))
        return 0
    if len(args) < 8:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    in_path, out_path = args[0], args[1]
    x, y, w, h = (float(value) for value in args[2:6])
    space = minx = None
    index = 6
    while index < len(args):
        if args[index] == "--space" and index + 1 < len(args):
            space = float(args[index + 1])
            index += 2
        elif args[index] == "--minx" and index + 1 < len(args):
            minx = float(args[index + 1])
            index += 2
        else:
            print("unknown argument %s" % args[index], file=sys.stderr)
            return 2
    if not space or space <= 0:
        print("--space must be the positive width of the display space", file=sys.stderr)
        return 2
    if minx is None:
        minx = 0
    width, height, pixels = decode(in_path)
    scale = width / space
    crop_x = max(0, min(int(round((x - minx) * scale)), width - 1))
    crop_y = max(0, min(int(round(y * scale)), height - 1))
    crop_w = max(1, min(int(round(w * scale)), width - crop_x))
    crop_h = max(1, min(int(round(h * scale)), height - crop_y))
    write_png(out_path, crop_w, crop_h, crop(pixels, width, height, crop_x, crop_y, crop_w, crop_h))
    print(json.dumps({
        "points": [x, y, w, h],
        "scale": round(scale, 4),
        "pixels": [crop_x, crop_y, crop_w, crop_h],
        "out": out_path,
    }))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except (OSError, ValueError, KeyError) as error:
        print("png-crop.py: %s" % error, file=sys.stderr)
        sys.exit(1)
