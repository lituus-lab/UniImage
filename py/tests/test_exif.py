# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Self-contained pytest over the Cython binding (no external fixture)."""
import json

import uniimage


def test_version():
    assert uniimage.version() == "1.0.0"


def test_abi_version():
    assert uniimage.abi_version() == 1


def test_minimal_jpeg_no_metadata():
    m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
    assert m.is_valid is False
    assert m.orientation == 0
    j = json.loads(m.to_json())
    assert j["isValid"] is False


def test_strip_round_trip():
    out = uniimage.strip_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
    assert out[:2] == b"\xff\xd8"


def test_strip_non_image_raises():
    try:
        uniimage.strip_buffer(bytes([0x00, 0x01, 0x02, 0x03]))
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_edit_round_trip():
    jpg = bytes([0xFF, 0xD8, 0xFF, 0xD9])
    e = uniimage.edit_buffer(jpg)
    e.set_artist("Jane Doe")
    e.set_software("UniImage")
    e.set_tag("ImageDescription", "py test")
    e.set_tag("ISO", "400")
    edited = e.write()
    assert edited[:2] == b"\xff\xd8"
    assert len(edited) > len(jpg)
    m = uniimage.read_buffer(edited)
    assert m.get_tag("Artist") == "Jane Doe"
    assert m.get_tag("ImageDescription") == "py test"
    assert m.get_tag("ISO") == "400"


def test_edit_unknown_tag_raises():
    e = uniimage.edit_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
    try:
        e.set_tag("NoSuchTag", "x")
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_tags_dict_is_empty_for_minimal_jpeg():
    m = uniimage.read_buffer(bytes([0xFF, 0xD8, 0xFF, 0xD9]))
    assert m.tags == {}
