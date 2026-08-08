# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Self-contained pytest over the ui_image_* Cython surface (no fixture)."""
import pytest

import uniimage

# A 2x2 RGB P6 PPM: red, green, blue, white.
PPM = b"P6\n2 2\n255\n" + bytes(
    [0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]
)


def test_image_abi_version():
    assert uniimage.image_abi_version() == 1


def test_decode_and_props():
    img = uniimage.decode_buffer(PPM)
    assert img.width == 2
    assert img.height == 2
    assert img.channels == 3
    assert img.colorspace == uniimage.CS_RGB


def test_image_from_pixels_copies_a_valid_buffer():
    pixels = PPM[11:]
    img = uniimage.image_from_pixels(2, 2, pixels, uniimage.CS_RGB)
    assert img.pixels == pixels
    with pytest.raises(ValueError):
        uniimage.image_from_pixels(2, 2, pixels[:-1], uniimage.CS_RGB)


@pytest.mark.parametrize(
    "algorithm", ["wu", "kmeans", "kmeansPP", "medianCut", "octree", "neuquant"]
)
def test_extract_palette_exposes_all_historical_quantizers(algorithm):
    palette = uniimage.decode_buffer(PPM).extract_palette(
        3, algorithm, seed=7, max_iter=20
    )
    assert 0 < len(palette) <= 3
    assert palette.seed == 7
    assert len(palette.colors) == len(palette)
    color = palette.color_at(0)
    assert color.space_tag == uniimage.COLOR_SPACE_OKLAB
    assert len(color.components) == 3
    assert 0.0 <= color.alpha <= 1.0
    with pytest.raises(IndexError):
        palette.color_at(len(palette))


def test_extract_palette_rejects_invalid_requests():
    img = uniimage.decode_buffer(PPM)
    with pytest.raises(ValueError):
        img.extract_palette(0)
    with pytest.raises(ValueError):
        img.extract_palette(2, "missing")


def test_pixels_borrow_copy():
    img = uniimage.decode_buffer(PPM)
    px = img.pixels
    assert len(px) == 2 * 2 * 3
    assert px[0] == 0xFF and px[1] == 0x00 and px[2] == 0x00  # red
    assert px[9] == 0xFF and px[10] == 0xFF and px[11] == 0xFF  # white


def test_resize_crop_rotate_encode_roundtrip():
    img = uniimage.decode_buffer(PPM)
    big = img.resize(4, 4, uniimage.FILTER_BILINEAR)
    assert big.width == 4 and big.height == 4
    cell = big.crop(1, 1, 2, 2)
    assert cell.width == 2 and cell.height == 2
    rot = cell.rotate(uniimage.ROT_90)
    assert rot.width == 2 and rot.height == 2
    png = rot.encode(uniimage.FMT_PNG)
    assert png[:4] == b"\x89PNG"
    back = uniimage.decode_buffer(png)
    assert back.width == 2 and back.height == 2
    assert back.channels == 3


def test_tga_hint_roundtrip():
    img = uniimage.decode_buffer(PPM)
    tga = img.encode(uniimage.FMT_TGA)
    tback = uniimage.decode_buffer(tga, uniimage.FMT_TGA)
    assert tback.width == 2 and tback.height == 2


def test_exif_orientation():
    img = uniimage.decode_buffer(PPM)
    oriented = img.orient(6)
    assert oriented.width == 2 and oriented.height == 2
    assert oriented.pixels == bytes(
        [0x00, 0x00, 0xFF, 0xFF, 0x00, 0x00,
         0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0x00]
    )
    with pytest.raises(ValueError):
        img.orient(0)


def test_thumbnail_without_exif_raises():
    with pytest.raises(ValueError):
        uniimage.thumbnail(PPM)


def test_decode_only_format_constants_are_exported():
    assert uniimage.FMT_WEBP == 9
    assert uniimage.FMT_TIFF == 10


def test_bad_input_raises():
    with pytest.raises(ValueError):
        uniimage.decode_buffer(b"\x00\x01\x02\x03")


def test_encode_unsupported_raises():
    img = uniimage.decode_buffer(PPM)
    with pytest.raises(ValueError):
        img.encode(uniimage.FMT_GIF)  # GIF has no encoder


def test_resize_bad_dims_raises():
    img = uniimage.decode_buffer(PPM)
    with pytest.raises(ValueError):
        img.resize(0, 2)


def test_crop_out_of_bounds_raises():
    img = uniimage.decode_buffer(PPM)
    with pytest.raises(ValueError):
        img.crop(1, 1, 9, 9)  # sub-rect overruns the 2x2 source


def test_crop_negative_raises():
    img = uniimage.decode_buffer(PPM)
    with pytest.raises(ValueError):
        img.crop(-1, 0, 2, 2)
