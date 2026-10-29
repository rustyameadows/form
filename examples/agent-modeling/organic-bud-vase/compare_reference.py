#!/usr/bin/env python3
"""Measure a rendered outline against the unchanged AI design reference.

These descriptive image metrics do not determine visual or physical acceptance.
The warm-color mask is specific to this ivory fixture and its neutral background.
Requires Pillow and NumPy. It never edits either input image.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


HERE = Path(__file__).resolve().parent
CROPS = {"front": (0, 0, 648, 750), "top": (648, 0, 1294, 750),
         "three-quarter": (1294, 0, 1942, 750)}


def outline(path, crop=None):
    image = Image.open(path).convert("RGB")
    if crop:
        image = image.crop(crop)
    pixels = np.asarray(image).astype(int)
    warm = ((pixels[:, :, 0] - pixels[:, :, 2]) > 8) & (
        (pixels[:, :, 1] - pixels[:, :, 2]) > 3)
    # A copy gives floodfill a writable image. Fill enclosed openings because
    # this comparison measures the outer silhouette, not cavity appearance.
    filled = Image.fromarray(warm.astype("uint8") * 255).copy()
    ImageDraw.floodfill(filled, (0, 0), 128)
    assert filled.getpixel((0, 0)) == 128
    mask = np.asarray(filled) != 128
    assert 0.05 < mask.mean() < 0.95, "The fixture's color segmentation failed."
    return mask


def dimensions(mask):
    y, x = np.nonzero(mask)
    return x.mean(), y.mean(), int(x.max() - x.min()), int(y.max() - y.min())


def harmonics(mask):
    cx, cy, _, _ = dimensions(mask)
    theta = np.linspace(0, 2 * math.pi, 720, endpoint=False)
    radius = np.arange(0, math.hypot(*mask.shape), 0.25)
    x = np.rint(cx + np.cos(theta)[:, None] * radius).astype(int)
    y = np.rint(cy - np.sin(theta)[:, None] * radius).astype(int)
    valid = (x >= 0) & (x < mask.shape[1]) & (y >= 0) & (y < mask.shape[0])
    hits = np.zeros_like(valid)
    hits[valid] = mask[y[valid], x[valid]]
    radial = (hits * radius).max(axis=1)
    names, columns = ["mean"], [np.ones_like(theta)]
    for degree in range(1, 7):
        names.extend([f"cos{degree}", f"sin{degree}"])
        columns.extend([np.cos(theta * degree), np.sin(theta * degree)])
    coefficients = np.linalg.lstsq(np.asarray(columns).T, radial, rcond=None)[0]
    return {name: float(value / coefficients[0])
            for name, value in zip(names, coefficients)}


def compare(image, view):
    reference = HERE / "ai-generated-reference.png"
    manifest = json.loads((HERE / "reference-manifest.json").read_text())
    reference_sha = hashlib.sha256(reference.read_bytes()).hexdigest()
    assert reference_sha == manifest["sha256"], "The frozen reference changed."
    expected, actual = outline(reference, CROPS[view]), outline(image)
    ex, ey, ew, eh = dimensions(expected)
    ax, ay, aw, ah = dimensions(actual)
    scale = math.sqrt(expected.sum() / actual.sum())
    y, x = np.indices(expected.shape)
    ix = np.rint((x - ex) / scale + ax).astype(int)
    iy = np.rint((y - ey) / scale + ay).astype(int)
    valid = (ix >= 0) & (ix < actual.shape[1]) & (iy >= 0) & (iy < actual.shape[0])
    registered = np.zeros(expected.shape, dtype=bool)
    registered[valid] = actual[iy[valid], ix[valid]]
    result = dict(
        image=str(image.resolve()), image_sha256=hashlib.sha256(image.read_bytes()).hexdigest(),
        reference_sha256=reference_sha, view=view,
        registration="Centroid translation and equal-area uniform scale; no rotation, stretch or local warp.",
        outer_silhouette_iou=float((expected & registered).sum() / (expected | registered).sum()),
        reference_height_width=eh / ew, render_height_width=ah / aw,
        reference_mask_pixels=int(expected.sum()), render_mask_pixels=int(actual.sum()),
        visual_acceptance="Not determined by these metrics. Inspect all views, blends, relief and cavity; validate the physical model separately.")
    if view == "top":
        result["reference_normalized_radial_harmonics"] = harmonics(expected)
        result["render_normalized_radial_harmonics"] = harmonics(actual)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("--view", choices=CROPS, default="top")
    parser.add_argument("--output", type=Path)
    arguments = parser.parse_args()
    result = json.dumps(compare(arguments.image, arguments.view), indent=2) + "\n"
    if arguments.output:
        arguments.output.write_text(result)
    print(result, end="")
