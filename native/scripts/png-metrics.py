#!/usr/bin/env python3
"""Statistics of one or two PNG files, decoded once per file.

A thin wrapper around png-stats.py for the regression tests: when two images
are compared the statistics of both and the difference are computed from a
single decode of each, instead of png-stats.py decoding the first image a
second time for the comparison. No third-party modules.

Usage:
  png-metrics.py <image.png> [--compare <other.png>]

Prints one JSON object: the statistics of the first image, plus — with the
--compare option — the statistics of the second image under "other" and the
difference under "compare" (compare.mean_abs_diff, compare.differing_pixels).
"""

import importlib.util
import json
import os
import sys

_spec = importlib.util.spec_from_file_location(
    "png_stats", os.path.join(os.path.dirname(os.path.abspath(__file__)), "png-stats.py"))
png_stats = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(png_stats)


def statistics(path, width, height, channels, pixels):
    count = width * height
    values = [png_stats.luma(pixels, channels, index) for index in range(count)]
    ordered = sorted(values)
    # The opaque dark pixels: the ink of the break buttons (the theme colour at
    # full opacity). Only the pixels that are not transparent are counted, so a
    # transparent background does not show up as ink.
    dark = 0
    if channels == 4:
        alpha = pixels[3::4]
        dark = sum(1 for a, value in zip(alpha, values) if a >= 128 and value <= 45)
    return {
        "file": path,
        "width": width,
        "height": height,
        "pixels": count,
        "median": ordered[count // 2],
        "p99": ordered[int(count * 0.99)],
        "contrast": sum(1 for value in values if value >= ordered[count // 2] + 25),
        "dark": dark,
        "mean": [round(value, 2) for value in
                 [sum(pixels[channel::channels]) / count for channel in range(min(3, channels))]],
    }


def compare(first, second):
    width1, height1, channels1, pixels1 = first
    width2, height2, channels2, pixels2 = second
    if (width1, height1) != (width2, height2):
        return {"comparable": False, "first": [width1, height1], "second": [width2, height2]}
    total = 0
    differing = 0
    for index in range(width1 * height1):
        base = index * channels1
        other_base = index * channels2
        delta = 0
        for channel in range(min(3, channels1, channels2)):
            delta += abs(pixels1[base + channel] - pixels2[other_base + channel])
        total += delta
        if delta > 24:
            differing += 1
    return {
        "comparable": True,
        "mean_abs_diff": round(total / max(1, width1 * height1 * 3), 3),
        "differing_pixels": differing,
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    first = png_stats.read_png(argv[1])
    result = statistics(argv[1], *first)
    if "--compare" in argv:
        index = argv.index("--compare")
        if index + 1 >= len(argv):
            print("the --compare option needs a second file", file=sys.stderr)
            return 2
        second = png_stats.read_png(argv[index + 1])
        result["other"] = statistics(argv[index + 1], *second)
        result["compare"] = compare(first, second)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
