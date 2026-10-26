#!/usr/bin/env python3
"""Independently inspect the Home-only proof. Requires Pillow and pypdf.

Usage: verify_home_technical_preview.py PROOF_DIR [--original-package PATH
       --original-hashes JSON] [--baseline-render PNG] [--output JSON]
No app, project, cached thumbnail or physical output is changed.
"""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageChops, ImageFilter
from pypdf import PdfReader


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ink(image):
    image = image.convert("RGB")
    delta = ImageChops.difference(image, Image.new("RGB", image.size, (231, 231, 225)))
    channels = delta.split()
    return ImageChops.lighter(ImageChops.lighter(channels[0], channels[1]), channels[2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("proof", type=Path)
    parser.add_argument("--original-package", type=Path)
    parser.add_argument("--original-hashes", type=Path)
    parser.add_argument("--baseline-render", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    before = Image.open(args.proof / "before-1000.png").convert("RGBA")
    after = Image.open(args.proof / "after-1000.png").convert("RGBA")
    assert before.size == after.size == (1000, 650)
    assert before.tobytes() != after.tobytes()
    old_ink, new_ink = ink(before), ink(after)
    support = lambda image: image.point(lambda value: 255 if value else 0)
    old_mask, new_mask = support(old_ink), support(new_ink)
    # A one-pixel centered display stroke may expand anti-aliased coverage by at
    # most two pixels. This catches a reframed/translated thumbnail independently.
    assert not ImageChops.subtract(old_mask, new_mask.filter(ImageFilter.MaxFilter(5))).getbbox()
    assert not ImageChops.subtract(new_mask, old_mask.filter(ImageFilter.MaxFilter(5))).getbbox()
    report = {
        "cached_size_pixels": list(before.size),
        "before_maximum_channel_contrast": old_ink.getextrema()[1],
        "after_maximum_channel_contrast": new_ink.getextrema()[1],
        "before_pixels_over_20_contrast": sum(old_ink.histogram()[21:]),
        "after_pixels_over_20_contrast": sum(new_ink.histogram()[21:]),
        "ink_support_preserved_with_two_pixel_allowance": True,
    }
    assert report["after_pixels_over_20_contrast"] > report["before_pixels_over_20_contrast"] * 5
    if args.baseline_render:
        assert Image.open(args.baseline_render).convert("RGBA").tobytes() == before.tobytes()
        report["original_default_render_pixel_identical"] = True
    assert (args.proof / "physical-before.svg").read_bytes() == (args.proof / "physical-after.svg").read_bytes()
    first, second = [PdfReader(args.proof / f"physical-{label}.pdf") for label in ("before", "after")]
    assert len(first.pages) == len(second.pages)
    boxes = []
    for a, b in zip(first.pages, second.pages):
        assert list(a.mediabox) == list(b.mediabox)
        assert a.get_contents().get_data() == b.get_contents().get_data()
        boxes.append([float(n) for n in a.mediabox])
    report.update(physical_svg_sha256=sha(args.proof / "physical-before.svg"),
                  physical_pdf_page_content_identical=True, physical_pdf_media_boxes_points=boxes)
    if args.original_package or args.original_hashes:
        assert args.original_package and args.original_hashes
        expected = json.loads(args.original_hashes.read_text())
        actual = {str(path.relative_to(args.original_package)): sha(path)
                  for path in args.original_package.rglob("*") if path.is_file()}
        assert expected == actual
        report["every_original_package_file_and_cached_preview_unchanged"] = True
    report["configuration"] = args.configuration
    report["native_hosted_card_cost"] = json.loads((args.proof / "native-card-cost.json").read_text())
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded)
    print(encoded, end="")


if __name__ == "__main__":
    main()
