#!/usr/bin/env python3
"""Pixel statistics of a PNG file, without third-party modules.

Used by the native regression tests to tell a visible break window from an empty
one: the break content is white text on a dark (or blurred) background, so the
number of pixels that are clearly brighter than the median of the image is the
"content is visible" signal. With --compare the mean absolute difference and the
number of differing pixels of two images are reported as well — that is how the
blurred background is told apart from the plain one.

Usage:
  png-stats.py <image.png> [--compare <other.png>]

Prints one JSON object.
"""

import json
import struct
import sys
import zlib


def read_png(path):
    """Returns (width, height, channels, pixels) of a non-interlaced 8 bit PNG."""
    with open(path, "rb") as handle:
        data = handle.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("%s is not a PNG" % path)
    position = 8
    idat = b""
    width = height = depth = color = 0
    while position < len(data):
        (length,) = struct.unpack(">I", data[position:position + 4])
        kind = data[position + 4:position + 8]
        chunk = data[position + 8:position + 8 + length]
        position += 12 + length
        if kind == b"IHDR":
            width, height, depth, color, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or interlace != 0:
                raise ValueError("unsupported PNG (depth %d, interlace %d)" % (depth, interlace))
        elif kind == b"IDAT":
            idat += chunk
        elif kind == b"IEND":
            break
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color]
    raw = zlib.decompress(idat)
    stride = width * channels
    pixels = bytearray(height * stride)
    previous = bytearray(stride)
    offset = 0
    for row in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride
        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = previous[i]
                c = previous[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                if pa <= pb and pa <= pc:
                    predictor = a
                elif pb <= pc:
                    predictor = b
                else:
                    predictor = c
                line[i] = (line[i] + predictor) & 0xFF
        pixels[row * stride:(row + 1) * stride] = line
        previous = line
    return width, height, channels, pixels


def luma(pixels, channels, index):
    base = index * channels
    if channels >= 3:
        red, green, blue = pixels[base], pixels[base + 1], pixels[base + 2]
    else:
        red = green = blue = pixels[base]
    return (red * 299 + green * 587 + blue * 114) // 1000


def statistics(path):
    width, height, channels, pixels = read_png(path)
    count = width * height
    values = [luma(pixels, channels, index) for index in range(count)]
    ordered = sorted(values)
    median = ordered[count // 2]
    bright = sum(1 for value in values if value >= median + 25)
    highest = ordered[int(count * 0.99)]
    mean = [sum(pixels[channel::channels]) / count for channel in range(min(3, channels))]
    return {
        "file": path,
        "width": width,
        "height": height,
        "pixels": count,
        "median": median,
        "p99": highest,
        "contrast": bright,
        "mean": [round(value, 2) for value in mean],
    }


def compare(first, second):
    width, height, channels, pixels = read_png(first)
    other_width, other_height, other_channels, other = read_png(second)
    if (width, height) != (other_width, other_height):
        return {"comparable": False, "first": [width, height], "second": [other_width, other_height]}
    total = 0
    differing = 0
    for index in range(width * height):
        base = index * channels
        other_base = index * other_channels
        delta = 0
        for channel in range(min(3, channels, other_channels)):
            delta += abs(pixels[base + channel] - other[other_base + channel])
        total += delta
        if delta > 24:
            differing += 1
    return {
        "comparable": True,
        "mean_abs_diff": round(total / max(1, width * height * 3), 3),
        "differing_pixels": differing,
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    result = statistics(argv[1])
    if "--compare" in argv:
        index = argv.index("--compare")
        result["compare"] = compare(argv[1], argv[index + 1])
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
