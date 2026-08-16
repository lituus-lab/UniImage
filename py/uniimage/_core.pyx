# cython: language_level=3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 lituus-lab
"""Cython binding over the UniImage C ABI."""
from libc.stddef cimport size_t
from libc.stdint cimport int32_t, int64_t
from libc.stdlib cimport malloc, free
from libc.string cimport memcpy
cimport cython


cdef extern from "UniImage.h":
    const char *ui_version()
    void   ui_exif_init()
    int    ui_exif_abi_version()
    const char *ui_exif_strerror(int code)

    ctypedef void* ui_exif_meta
    ctypedef void* ui_exif_edit

    int    ui_exif_read_buffer(const unsigned char* data, size_t length,
                               ui_exif_meta* out_handle)
    int    ui_exif_is_valid(ui_exif_meta h)
    size_t ui_exif_tag_count(ui_exif_meta h)
    int    ui_exif_tag_at(ui_exif_meta h, size_t i,
                         const char** out_name, const char** out_value)
    const char* ui_exif_get_tag(ui_exif_meta h, const char* name)
    int    ui_exif_get_gps(ui_exif_meta h, double* lat, double* lon, double* alt)
    int    ui_exif_get_orientation(ui_exif_meta h)
    const char* ui_exif_to_json(ui_exif_meta h)
    void   ui_exif_meta_free(ui_exif_meta h)

    int    ui_exif_strip_buffer(const unsigned char* data, size_t length,
                                unsigned char** out_data, size_t* out_len)
    void   ui_exif_buffer_free(unsigned char* buffer)

    int    ui_exif_edit_open_buffer(const unsigned char* data, size_t length,
                                    ui_exif_edit* out_handle)
    void   ui_exif_set_artist(ui_exif_edit h, const char* value)
    void   ui_exif_set_software(ui_exif_edit h, const char* value)
    void   ui_exif_set_datetime(ui_exif_edit h, const char* value)
    void   ui_exif_set_gps(ui_exif_edit h, double lat, double lon, double alt)
    int    ui_exif_edit_set_tag(ui_exif_edit h, const char* name, const char* value)
    int    ui_exif_edit_write_buffer(ui_exif_edit h, unsigned char** out_data,
                                     size_t* out_len)
    void   ui_exif_edit_free(ui_exif_edit h)

    # ui_image_* codec + process surface
    int    ui_image_abi_version()
    const char* ui_image_strerror(int code)
    ctypedef void* ui_image
    ctypedef struct ui_color:
        float comps[4]
        int32_t tag
    ctypedef struct ui_quantize_options:
        int64_t seed
        int max_iter
        int weighting
        int parallel
        int threads
    ctypedef void* ui_palette
    int    ui_image_from_pixels(int width, int height, int colorspace,
                                const unsigned char* data, size_t length,
                                ui_image* out_handle)
    int    ui_image_decode_buffer(const unsigned char* data, size_t length,
                                  int fmt, ui_image* out_handle)
    int    ui_image_thumbnail(const unsigned char* data, size_t length,
                              ui_image* out_handle)
    int    ui_image_encode(ui_image h, int fmt, int quality,
                           unsigned char** out_data, size_t* out_len)
    int    ui_image_width(ui_image h)
    int    ui_image_height(ui_image h)
    int    ui_image_channels(ui_image h)
    int    ui_image_get_colorspace(ui_image h)
    int    ui_image_pixels(ui_image h, unsigned char** out_ptr, size_t* out_len)
    int    ui_image_composite_over(ui_image destination, ui_image source,
                                   int x, int y, int opacity)
    int    ui_image_resize(ui_image h, int w, int height, int filter,
                           ui_image* out_handle)
    int    ui_image_crop(ui_image h, int x, int y, int w, int height,
                         ui_image* out_handle)
    int    ui_image_rotate(ui_image h, int op, ui_image* out_handle)
    int    ui_image_apply_orientation(ui_image h, int orientation,
                                      ui_image* out_handle)
    int    ui_image_extract_palette(ui_image h, int n, const char* algo,
                                    int32_t space_tag,
                                    const ui_quantize_options* options,
                                    ui_palette* out_handle)
    size_t ui_palette_len(ui_palette p)
    int    ui_palette_color_at(ui_palette p, size_t i, ui_color* out_color)
    int    ui_palette_tag(ui_palette p)
    int    ui_palette_intent(ui_palette p)
    int64_t ui_palette_seed(ui_palette p)
    void   ui_palette_free(ui_palette p)
    void   ui_image_free(ui_image h)
    void   ui_image_buffer_free(unsigned char* buffer, size_t len)


cdef class _Meta:
    cdef ui_exif_meta _h

    def __cinit__(self):
        self._h = NULL

    def __dealloc__(self):
        if self._h != NULL:
            ui_exif_meta_free(self._h)
            self._h = NULL

    @property
    def is_valid(self):
        return bool(ui_exif_is_valid(self._h))

    @property
    def orientation(self):
        return ui_exif_get_orientation(self._h)

    @property
    def gps(self):
        cdef double lat = 0.0, lon = 0.0, alt = 0.0
        if ui_exif_get_gps(self._h, &lat, &lon, &alt):
            return (lat, lon, alt)
        return None

    def get_tag(self, name):
        cdef const char* v = ui_exif_get_tag(self._h, name.encode("ascii"))
        if v == NULL:
            return None
        return (<bytes>v).decode("utf-8", "replace")

    @property
    def tags(self):
        cdef size_t n = ui_exif_tag_count(self._h)
        cdef size_t i
        cdef const char* nm
        cdef const char* val
        out = {}
        for i in range(n):
            if ui_exif_tag_at(self._h, i, &nm, &val) == 0:
                out[(<bytes>nm).decode("utf-8", "replace")] = (<bytes>val).decode("utf-8", "replace")
        return out

    def to_json(self):
        cdef const char* j = ui_exif_to_json(self._h)
        if j == NULL:
            return None
        return (<bytes>j).decode("utf-8", "replace")


cdef class _Edit:
    cdef ui_exif_edit _h

    def __cinit__(self):
        self._h = NULL

    def __dealloc__(self):
        if self._h != NULL:
            ui_exif_edit_free(self._h)
            self._h = NULL

    def set_artist(self, value):
        ui_exif_set_artist(self._h, value.encode("utf-8"))

    def set_software(self, value):
        ui_exif_set_software(self._h, value.encode("utf-8"))

    def set_datetime(self, value):
        ui_exif_set_datetime(self._h, value.encode("ascii"))

    def set_gps(self, double lat, double lon, double alt):
        ui_exif_set_gps(self._h, lat, lon, alt)

    def set_tag(self, name, value):
        rc = ui_exif_edit_set_tag(self._h, name.encode("utf-8"), value.encode("utf-8"))
        if rc != 0:
            raise ValueError(f"set_tag {name!r} failed: {strerror(rc)}")

    def write(self):
        cdef unsigned char* out = NULL
        cdef size_t out_len = 0
        rc = ui_exif_edit_write_buffer(self._h, &out, &out_len)
        if rc != 0:
            raise ValueError(f"edit write failed: {strerror(rc)}")
        try:
            return bytes(<unsigned char[:out_len]>out)
        finally:
            ui_exif_buffer_free(out)


def strerror(int code):
    cdef const char* s = ui_exif_strerror(code)
    if s == NULL:
        return f"error {code}"
    return (<bytes>s).decode("ascii")


def image_strerror(int code):
    cdef const char* s = ui_image_strerror(code)
    if s == NULL:
        return f"image error {code}"
    return (<bytes>s).decode("ascii")


def version():
    return (<bytes>ui_version()).decode("ascii")


def abi_version():
    return ui_exif_abi_version()


def init():
    ui_exif_init()


def read_buffer(data):
    """Parse metadata from an in-memory image buffer (bytes)."""
    cdef ui_exif_meta h = NULL
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_exif_read_buffer(buf, length, &h)
    if rc != 0:
        raise ValueError(f"read_buffer failed: {strerror(rc)}")
    r = _Meta()
    r._h = h
    return r


def strip_buffer(data):
    """Return a copy of `data` with metadata removed."""
    cdef unsigned char* out = NULL
    cdef size_t out_len = 0
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_exif_strip_buffer(buf, length, &out, &out_len)
    if rc != 0:
        raise ValueError(f"strip_buffer failed: {strerror(rc)}")
    try:
        return bytes(<unsigned char[:out_len]>out)
    finally:
        ui_exif_buffer_free(out)


def edit_buffer(data):
    """Open an editable EXIF model from an in-memory buffer (bytes are copied)."""
    cdef ui_exif_edit h = NULL
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_exif_edit_open_buffer(buf, length, &h)
    if rc != 0:
        raise ValueError(f"edit_buffer failed: {strerror(rc)}")
    e = _Edit()
    e._h = h
    return e


# ---- ui_image_* codec + process surface -----------------------------------
# Format / filter / rotate / colorspace constants — mirror the C enums in
# UniImage.h so callers pass `uniimage.FMT_PNG`, `uniimage.FILTER_BILINEAR`,
# etc. rather than raw ints.
FMT_AUTO = 0
FMT_PNG = 1
FMT_JPEG = 2
FMT_BMP = 3
FMT_QOI = 4
FMT_PNM = 5
FMT_GIF = 6
FMT_PCX = 7
FMT_TGA = 8
FMT_WEBP = 9
FMT_TIFF = 10

FILTER_NEAREST = 0
FILTER_BILINEAR = 1
FILTER_BOX = 2

ROT_90 = 0
ROT_180 = 1
ROT_270 = 2
FLIP_H = 3
FLIP_V = 4

CS_GRAY = 0
CS_RGB = 1
CS_RGBA = 2
CS_CMYK = 3
CS_YUV = 4
CS_INDEXED = 5

COLOR_SPACE_DEFAULT = 0
COLOR_SPACE_SRGB = 1
COLOR_SPACE_OKLAB = 15


cdef class Color:
    """A quantized UniColor value: three components, straight alpha and an
    ABI-stable color-space tag."""

    cdef ui_color _c

    @property
    def components(self):
        return (self._c.comps[0], self._c.comps[1], self._c.comps[2])

    @property
    def alpha(self):
        return self._c.comps[3]

    @property
    def space_tag(self):
        return self._c.tag


cdef class Palette:
    """An immutable palette extracted by UniColor. Freeing is automatic."""

    cdef ui_palette _h

    def __cinit__(self):
        self._h = NULL

    def __dealloc__(self):
        if self._h != NULL:
            ui_palette_free(self._h)
            self._h = NULL

    def __len__(self):
        return ui_palette_len(self._h)

    def color_at(self, size_t index):
        cdef ui_color color
        rc = ui_palette_color_at(self._h, index, &color)
        if rc != 0:
            raise IndexError(index)
        result = Color()
        result._c = color
        return result

    @property
    def colors(self):
        return [self.color_at(i) for i in range(len(self))]

    @property
    def tag(self):
        return ui_palette_tag(self._h)

    @property
    def intent(self):
        return ui_palette_intent(self._h)

    @property
    def seed(self):
        return ui_palette_seed(self._h)


cdef class Image:
    """An 8-bit decoded image. The library owns the pixel buffer; `pixels`
    returns a copy. Freeing is automatic on GC."""

    cdef ui_image _h

    def __cinit__(self):
        self._h = NULL

    def __dealloc__(self):
        if self._h != NULL:
            ui_image_free(self._h)
            self._h = NULL

    @property
    def width(self):
        return ui_image_width(self._h)

    @property
    def height(self):
        return ui_image_height(self._h)

    @property
    def channels(self):
        return ui_image_channels(self._h)

    @property
    def colorspace(self):
        return ui_image_get_colorspace(self._h)

    @property
    def pixels(self):
        cdef unsigned char* p = NULL
        cdef size_t n = 0
        rc = ui_image_pixels(self._h, &p, &n)
        if rc != 0:
            raise ValueError(f"pixels failed: {image_strerror(rc)}")
        if p == NULL or n == 0:
            return b""
        return bytes(<unsigned char[:n]>p)

    def encode(self, int fmt, int quality=90):
        cdef unsigned char* out = NULL
        cdef size_t out_len = 0
        rc = ui_image_encode(self._h, fmt, quality, &out, &out_len)
        if rc != 0:
            raise ValueError(f"encode failed: {image_strerror(rc)}")
        try:
            return bytes(<unsigned char[:out_len]>out)
        finally:
            ui_image_buffer_free(out, out_len)

    def resize(self, int w, int h, int filter=FILTER_BILINEAR):
        cdef ui_image out = NULL
        rc = ui_image_resize(self._h, w, h, filter, &out)
        if rc != 0:
            raise ValueError(f"resize failed: {image_strerror(rc)}")
        r = Image()
        r._h = out
        return r

    def composite_over(self, Image source, int x, int y, int opacity=255):
        """Composite source over this RGBA image in place.

        Source may be Gray, RGB or straight-alpha RGBA. Placement is clipped
        and opacity is an integer from 0 through 255.
        """
        rc = ui_image_composite_over(self._h, source._h, x, y, opacity)
        if rc != 0:
            raise ValueError(f"composite_over failed: {image_strerror(rc)}")

    def crop(self, int x, int y, int w, int h):
        cdef ui_image out = NULL
        rc = ui_image_crop(self._h, x, y, w, h, &out)
        if rc != 0:
            raise ValueError(f"crop failed: {image_strerror(rc)}")
        r = Image()
        r._h = out
        return r

    def rotate(self, int op):
        cdef ui_image out = NULL
        rc = ui_image_rotate(self._h, op, &out)
        if rc != 0:
            raise ValueError(f"rotate failed: {image_strerror(rc)}")
        r = Image()
        r._h = out
        return r

    def orient(self, int orientation):
        """Return a copy transformed according to EXIF Orientation (1..8)."""
        cdef ui_image out = NULL
        rc = ui_image_apply_orientation(self._h, orientation, &out)
        if rc != 0:
            raise ValueError(f"orient failed: {image_strerror(rc)}")
        r = Image()
        r._h = out
        return r

    def extract_palette(self, int n, str algo="wu", int space=COLOR_SPACE_DEFAULT,
                        int64_t seed=0, int max_iter=20, bint weighting=False,
                        bint parallel=False, int threads=0):
        """Extract a palette with one of UniColor's six historical
        quantizers. Space 0 selects the OKLab default."""
        cdef ui_quantize_options opts
        cdef ui_palette out = NULL
        cdef bytes encoded_algo = algo.encode("ascii")
        opts.seed = seed
        opts.max_iter = max_iter
        opts.weighting = int(weighting)
        opts.parallel = int(parallel)
        opts.threads = threads
        rc = ui_image_extract_palette(self._h, n, encoded_algo, space, &opts,
                                      &out)
        if rc != 0:
            raise ValueError(
                f"palette extraction failed: {image_strerror(rc)}"
            )
        result = Palette()
        result._h = out
        return result


def image_abi_version():
    return ui_image_abi_version()


def image_from_pixels(int width, int height, data, int colorspace=CS_RGB):
    """Copy packed 8-bit pixels into a new owned `Image`."""
    cdef ui_image h = NULL
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_image_from_pixels(width, height, colorspace, buf, length, &h)
    if rc != 0:
        raise ValueError(f"image_from_pixels failed: {image_strerror(rc)}")
    result = Image()
    result._h = h
    return result


def decode_buffer(data, fmt=FMT_AUTO):
    """Decode an in-memory image (bytes). `fmt` defaults to AUTO (sniff the
    magic); pass FMT_TGA to decode a TGA (no magic). Returns an `Image`."""
    cdef ui_image h = NULL
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_image_decode_buffer(buf, length, fmt, &h)
    if rc != 0:
        raise ValueError(f"decode_buffer failed: {image_strerror(rc)}")
    r = Image()
    r._h = h
    return r


def thumbnail(data):
    """Decode the embedded EXIF JPEG thumbnail from an image buffer."""
    cdef ui_image h = NULL
    cdef const unsigned char* buf
    cdef size_t length = len(data)
    if length == 0:
        buf = NULL
    else:
        buf = <const unsigned char*>data
    rc = ui_image_thumbnail(buf, length, &h)
    if rc != 0:
        raise ValueError(f"thumbnail failed: {image_strerror(rc)}")
    r = Image()
    r._h = h
    return r
