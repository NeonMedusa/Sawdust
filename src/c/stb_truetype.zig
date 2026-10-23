const __root = @This();
pub const __builtin = @import("std").zig.c_translation.builtins;
pub const __helpers = @import("std").zig.c_translation.helpers;
pub const stbtt__buf = extern struct {
    data: [*c]u8 = null,
    cursor: c_int = 0,
    size: c_int = 0,
};
pub const stbtt_bakedchar = extern struct {
    x0: c_ushort = 0,
    y0: c_ushort = 0,
    x1: c_ushort = 0,
    y1: c_ushort = 0,
    xoff: f32 = 0,
    yoff: f32 = 0,
    xadvance: f32 = 0,
    pub const stbtt_GetBakedQuad = __root.stbtt_GetBakedQuad;
    pub const GetBakedQuad = __root.stbtt_GetBakedQuad;
};
pub extern fn stbtt_BakeFontBitmap(data: [*c]const u8, offset: c_int, pixel_height: f32, pixels: [*c]u8, pw: c_int, ph: c_int, first_char: c_int, num_chars: c_int, chardata: [*c]stbtt_bakedchar) c_int;
pub const stbtt_aligned_quad = extern struct {
    x0: f32 = 0,
    y0: f32 = 0,
    s0: f32 = 0,
    t0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    s1: f32 = 0,
    t1: f32 = 0,
};
pub extern fn stbtt_GetBakedQuad(chardata: [*c]const stbtt_bakedchar, pw: c_int, ph: c_int, char_index: c_int, xpos: [*c]f32, ypos: [*c]f32, q: [*c]stbtt_aligned_quad, opengl_fillrule: c_int) void;
pub extern fn stbtt_GetScaledFontVMetrics(fontdata: [*c]const u8, index: c_int, size: f32, ascent: [*c]f32, descent: [*c]f32, lineGap: [*c]f32) void;
pub const stbtt_packedchar = extern struct {
    x0: c_ushort = 0,
    y0: c_ushort = 0,
    x1: c_ushort = 0,
    y1: c_ushort = 0,
    xoff: f32 = 0,
    yoff: f32 = 0,
    xadvance: f32 = 0,
    xoff2: f32 = 0,
    yoff2: f32 = 0,
    pub const stbtt_GetPackedQuad = __root.stbtt_GetPackedQuad;
    pub const GetPackedQuad = __root.stbtt_GetPackedQuad;
};
pub const struct_stbtt_pack_context = extern struct {
    user_allocator_context: ?*anyopaque = null,
    pack_info: ?*anyopaque = null,
    width: c_int = 0,
    height: c_int = 0,
    stride_in_bytes: c_int = 0,
    padding: c_int = 0,
    skip_missing: c_int = 0,
    h_oversample: c_uint = 0,
    v_oversample: c_uint = 0,
    pixels: [*c]u8 = null,
    nodes: ?*anyopaque = null,
    pub const stbtt_PackBegin = __root.stbtt_PackBegin;
    pub const stbtt_PackEnd = __root.stbtt_PackEnd;
    pub const stbtt_PackFontRange = __root.stbtt_PackFontRange;
    pub const stbtt_PackFontRanges = __root.stbtt_PackFontRanges;
    pub const stbtt_PackSetOversampling = __root.stbtt_PackSetOversampling;
    pub const stbtt_PackSetSkipMissingCodepoints = __root.stbtt_PackSetSkipMissingCodepoints;
    pub const stbtt_PackFontRangesGatherRects = __root.stbtt_PackFontRangesGatherRects;
    pub const stbtt_PackFontRangesPackRects = __root.stbtt_PackFontRangesPackRects;
    pub const stbtt_PackFontRangesRenderIntoRects = __root.stbtt_PackFontRangesRenderIntoRects;
    pub const PackBegin = __root.stbtt_PackBegin;
    pub const PackEnd = __root.stbtt_PackEnd;
    pub const PackFontRange = __root.stbtt_PackFontRange;
    pub const PackFontRanges = __root.stbtt_PackFontRanges;
    pub const PackSetOversampling = __root.stbtt_PackSetOversampling;
    pub const PackSetSkipMissingCodepoints = __root.stbtt_PackSetSkipMissingCodepoints;
    pub const PackFontRangesGatherRects = __root.stbtt_PackFontRangesGatherRects;
    pub const PackFontRangesPackRects = __root.stbtt_PackFontRangesPackRects;
    pub const PackFontRangesRenderIntoRects = __root.stbtt_PackFontRangesRenderIntoRects;
};
pub const stbtt_pack_context = struct_stbtt_pack_context;
pub const struct_stbtt_fontinfo = extern struct {
    userdata: ?*anyopaque = null,
    data: [*c]u8 = null,
    fontstart: c_int = 0,
    numGlyphs: c_int = 0,
    loca: c_int = 0,
    head: c_int = 0,
    glyf: c_int = 0,
    hhea: c_int = 0,
    hmtx: c_int = 0,
    kern: c_int = 0,
    gpos: c_int = 0,
    svg: c_int = 0,
    index_map: c_int = 0,
    indexToLocFormat: c_int = 0,
    cff: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    charstrings: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    gsubrs: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    subrs: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    fontdicts: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    fdselect: stbtt__buf = @import("std").mem.zeroes(stbtt__buf),
    pub const stbtt_InitFont = __root.stbtt_InitFont;
    pub const stbtt_FindGlyphIndex = __root.stbtt_FindGlyphIndex;
    pub const stbtt_ScaleForPixelHeight = __root.stbtt_ScaleForPixelHeight;
    pub const stbtt_ScaleForMappingEmToPixels = __root.stbtt_ScaleForMappingEmToPixels;
    pub const stbtt_GetFontVMetrics = __root.stbtt_GetFontVMetrics;
    pub const stbtt_GetFontVMetricsOS2 = __root.stbtt_GetFontVMetricsOS2;
    pub const stbtt_GetFontBoundingBox = __root.stbtt_GetFontBoundingBox;
    pub const stbtt_GetCodepointHMetrics = __root.stbtt_GetCodepointHMetrics;
    pub const stbtt_GetCodepointKernAdvance = __root.stbtt_GetCodepointKernAdvance;
    pub const stbtt_GetCodepointBox = __root.stbtt_GetCodepointBox;
    pub const stbtt_GetGlyphHMetrics = __root.stbtt_GetGlyphHMetrics;
    pub const stbtt_GetGlyphKernAdvance = __root.stbtt_GetGlyphKernAdvance;
    pub const stbtt_GetGlyphBox = __root.stbtt_GetGlyphBox;
    pub const stbtt_GetKerningTableLength = __root.stbtt_GetKerningTableLength;
    pub const stbtt_GetKerningTable = __root.stbtt_GetKerningTable;
    pub const stbtt_IsGlyphEmpty = __root.stbtt_IsGlyphEmpty;
    pub const stbtt_GetCodepointShape = __root.stbtt_GetCodepointShape;
    pub const stbtt_GetGlyphShape = __root.stbtt_GetGlyphShape;
    pub const stbtt_FreeShape = __root.stbtt_FreeShape;
    pub const stbtt_FindSVGDoc = __root.stbtt_FindSVGDoc;
    pub const stbtt_GetCodepointSVG = __root.stbtt_GetCodepointSVG;
    pub const stbtt_GetGlyphSVG = __root.stbtt_GetGlyphSVG;
    pub const stbtt_GetCodepointBitmap = __root.stbtt_GetCodepointBitmap;
    pub const stbtt_GetCodepointBitmapSubpixel = __root.stbtt_GetCodepointBitmapSubpixel;
    pub const stbtt_MakeCodepointBitmap = __root.stbtt_MakeCodepointBitmap;
    pub const stbtt_MakeCodepointBitmapSubpixel = __root.stbtt_MakeCodepointBitmapSubpixel;
    pub const stbtt_MakeCodepointBitmapSubpixelPrefilter = __root.stbtt_MakeCodepointBitmapSubpixelPrefilter;
    pub const stbtt_GetCodepointBitmapBox = __root.stbtt_GetCodepointBitmapBox;
    pub const stbtt_GetCodepointBitmapBoxSubpixel = __root.stbtt_GetCodepointBitmapBoxSubpixel;
    pub const stbtt_GetGlyphBitmap = __root.stbtt_GetGlyphBitmap;
    pub const stbtt_GetGlyphBitmapSubpixel = __root.stbtt_GetGlyphBitmapSubpixel;
    pub const stbtt_MakeGlyphBitmap = __root.stbtt_MakeGlyphBitmap;
    pub const stbtt_MakeGlyphBitmapSubpixel = __root.stbtt_MakeGlyphBitmapSubpixel;
    pub const stbtt_MakeGlyphBitmapSubpixelPrefilter = __root.stbtt_MakeGlyphBitmapSubpixelPrefilter;
    pub const stbtt_GetGlyphBitmapBox = __root.stbtt_GetGlyphBitmapBox;
    pub const stbtt_GetGlyphBitmapBoxSubpixel = __root.stbtt_GetGlyphBitmapBoxSubpixel;
    pub const stbtt_GetGlyphSDF = __root.stbtt_GetGlyphSDF;
    pub const stbtt_GetCodepointSDF = __root.stbtt_GetCodepointSDF;
    pub const stbtt_GetFontNameString = __root.stbtt_GetFontNameString;
    pub const InitFont = __root.stbtt_InitFont;
    pub const FindGlyphIndex = __root.stbtt_FindGlyphIndex;
    pub const ScaleForPixelHeight = __root.stbtt_ScaleForPixelHeight;
    pub const ScaleForMappingEmToPixels = __root.stbtt_ScaleForMappingEmToPixels;
    pub const GetFontVMetrics = __root.stbtt_GetFontVMetrics;
    pub const GetFontVMetricsOS2 = __root.stbtt_GetFontVMetricsOS2;
    pub const GetFontBoundingBox = __root.stbtt_GetFontBoundingBox;
    pub const GetCodepointHMetrics = __root.stbtt_GetCodepointHMetrics;
    pub const GetCodepointKernAdvance = __root.stbtt_GetCodepointKernAdvance;
    pub const GetCodepointBox = __root.stbtt_GetCodepointBox;
    pub const GetGlyphHMetrics = __root.stbtt_GetGlyphHMetrics;
    pub const GetGlyphKernAdvance = __root.stbtt_GetGlyphKernAdvance;
    pub const GetGlyphBox = __root.stbtt_GetGlyphBox;
    pub const GetKerningTableLength = __root.stbtt_GetKerningTableLength;
    pub const GetKerningTable = __root.stbtt_GetKerningTable;
    pub const IsGlyphEmpty = __root.stbtt_IsGlyphEmpty;
    pub const GetCodepointShape = __root.stbtt_GetCodepointShape;
    pub const GetGlyphShape = __root.stbtt_GetGlyphShape;
    pub const FreeShape = __root.stbtt_FreeShape;
    pub const FindSVGDoc = __root.stbtt_FindSVGDoc;
    pub const GetCodepointSVG = __root.stbtt_GetCodepointSVG;
    pub const GetGlyphSVG = __root.stbtt_GetGlyphSVG;
    pub const GetCodepointBitmap = __root.stbtt_GetCodepointBitmap;
    pub const GetCodepointBitmapSubpixel = __root.stbtt_GetCodepointBitmapSubpixel;
    pub const MakeCodepointBitmap = __root.stbtt_MakeCodepointBitmap;
    pub const MakeCodepointBitmapSubpixel = __root.stbtt_MakeCodepointBitmapSubpixel;
    pub const MakeCodepointBitmapSubpixelPrefilter = __root.stbtt_MakeCodepointBitmapSubpixelPrefilter;
    pub const GetCodepointBitmapBox = __root.stbtt_GetCodepointBitmapBox;
    pub const GetCodepointBitmapBoxSubpixel = __root.stbtt_GetCodepointBitmapBoxSubpixel;
    pub const GetGlyphBitmap = __root.stbtt_GetGlyphBitmap;
    pub const GetGlyphBitmapSubpixel = __root.stbtt_GetGlyphBitmapSubpixel;
    pub const MakeGlyphBitmap = __root.stbtt_MakeGlyphBitmap;
    pub const MakeGlyphBitmapSubpixel = __root.stbtt_MakeGlyphBitmapSubpixel;
    pub const MakeGlyphBitmapSubpixelPrefilter = __root.stbtt_MakeGlyphBitmapSubpixelPrefilter;
    pub const GetGlyphBitmapBox = __root.stbtt_GetGlyphBitmapBox;
    pub const GetGlyphBitmapBoxSubpixel = __root.stbtt_GetGlyphBitmapBoxSubpixel;
    pub const GetGlyphSDF = __root.stbtt_GetGlyphSDF;
    pub const GetCodepointSDF = __root.stbtt_GetCodepointSDF;
    pub const GetFontNameString = __root.stbtt_GetFontNameString;
};
pub const stbtt_fontinfo = struct_stbtt_fontinfo;
pub const struct_stbrp_rect = opaque {};
pub const stbrp_rect = struct_stbrp_rect;
pub extern fn stbtt_PackBegin(spc: [*c]stbtt_pack_context, pixels: [*c]u8, width: c_int, height: c_int, stride_in_bytes: c_int, padding: c_int, alloc_context: ?*anyopaque) c_int;
pub extern fn stbtt_PackEnd(spc: [*c]stbtt_pack_context) void;
pub extern fn stbtt_PackFontRange(spc: [*c]stbtt_pack_context, fontdata: [*c]const u8, font_index: c_int, font_size: f32, first_unicode_char_in_range: c_int, num_chars_in_range: c_int, chardata_for_range: [*c]stbtt_packedchar) c_int;
pub const stbtt_pack_range = extern struct {
    font_size: f32 = 0,
    first_unicode_codepoint_in_range: c_int = 0,
    array_of_unicode_codepoints: [*c]c_int = null,
    num_chars: c_int = 0,
    chardata_for_range: [*c]stbtt_packedchar = null,
    h_oversample: u8 = 0,
    v_oversample: u8 = 0,
};
pub extern fn stbtt_PackFontRanges(spc: [*c]stbtt_pack_context, fontdata: [*c]const u8, font_index: c_int, ranges: [*c]stbtt_pack_range, num_ranges: c_int) c_int;
pub extern fn stbtt_PackSetOversampling(spc: [*c]stbtt_pack_context, h_oversample: c_uint, v_oversample: c_uint) void;
pub extern fn stbtt_PackSetSkipMissingCodepoints(spc: [*c]stbtt_pack_context, skip: c_int) void;
pub extern fn stbtt_GetPackedQuad(chardata: [*c]const stbtt_packedchar, pw: c_int, ph: c_int, char_index: c_int, xpos: [*c]f32, ypos: [*c]f32, q: [*c]stbtt_aligned_quad, align_to_integer: c_int) void;
pub extern fn stbtt_PackFontRangesGatherRects(spc: [*c]stbtt_pack_context, info: [*c]const stbtt_fontinfo, ranges: [*c]stbtt_pack_range, num_ranges: c_int, rects: ?*stbrp_rect) c_int;
pub extern fn stbtt_PackFontRangesPackRects(spc: [*c]stbtt_pack_context, rects: ?*stbrp_rect, num_rects: c_int) void;
pub extern fn stbtt_PackFontRangesRenderIntoRects(spc: [*c]stbtt_pack_context, info: [*c]const stbtt_fontinfo, ranges: [*c]stbtt_pack_range, num_ranges: c_int, rects: ?*stbrp_rect) c_int;
pub extern fn stbtt_GetNumberOfFonts(data: [*c]const u8) c_int;
pub extern fn stbtt_GetFontOffsetForIndex(data: [*c]const u8, index: c_int) c_int;
pub extern fn stbtt_InitFont(info: [*c]stbtt_fontinfo, data: [*c]const u8, offset: c_int) c_int;
pub extern fn stbtt_FindGlyphIndex(info: [*c]const stbtt_fontinfo, unicode_codepoint: c_int) c_int;
pub extern fn stbtt_ScaleForPixelHeight(info: [*c]const stbtt_fontinfo, pixels: f32) f32;
pub extern fn stbtt_ScaleForMappingEmToPixels(info: [*c]const stbtt_fontinfo, pixels: f32) f32;
pub extern fn stbtt_GetFontVMetrics(info: [*c]const stbtt_fontinfo, ascent: [*c]c_int, descent: [*c]c_int, lineGap: [*c]c_int) void;
pub extern fn stbtt_GetFontVMetricsOS2(info: [*c]const stbtt_fontinfo, typoAscent: [*c]c_int, typoDescent: [*c]c_int, typoLineGap: [*c]c_int) c_int;
pub extern fn stbtt_GetFontBoundingBox(info: [*c]const stbtt_fontinfo, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) void;
pub extern fn stbtt_GetCodepointHMetrics(info: [*c]const stbtt_fontinfo, codepoint: c_int, advanceWidth: [*c]c_int, leftSideBearing: [*c]c_int) void;
pub extern fn stbtt_GetCodepointKernAdvance(info: [*c]const stbtt_fontinfo, ch1: c_int, ch2: c_int) c_int;
pub extern fn stbtt_GetCodepointBox(info: [*c]const stbtt_fontinfo, codepoint: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int;
pub extern fn stbtt_GetGlyphHMetrics(info: [*c]const stbtt_fontinfo, glyph_index: c_int, advanceWidth: [*c]c_int, leftSideBearing: [*c]c_int) void;
pub extern fn stbtt_GetGlyphKernAdvance(info: [*c]const stbtt_fontinfo, glyph1: c_int, glyph2: c_int) c_int;
pub extern fn stbtt_GetGlyphBox(info: [*c]const stbtt_fontinfo, glyph_index: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int;
pub const struct_stbtt_kerningentry = extern struct {
    glyph1: c_int = 0,
    glyph2: c_int = 0,
    advance: c_int = 0,
};
pub const stbtt_kerningentry = struct_stbtt_kerningentry;
pub extern fn stbtt_GetKerningTableLength(info: [*c]const stbtt_fontinfo) c_int;
pub extern fn stbtt_GetKerningTable(info: [*c]const stbtt_fontinfo, table: [*c]stbtt_kerningentry, table_length: c_int) c_int;
pub const STBTT_vmove: c_int = 1;
pub const STBTT_vline: c_int = 2;
pub const STBTT_vcurve: c_int = 3;
pub const STBTT_vcubic: c_int = 4;
const enum_unnamed_1 = c_uint;
pub const stbtt_vertex = extern struct {
    x: c_short = 0,
    y: c_short = 0,
    cx: c_short = 0,
    cy: c_short = 0,
    cx1: c_short = 0,
    cy1: c_short = 0,
    type: u8 = 0,
    padding: u8 = 0,
};
pub extern fn stbtt_IsGlyphEmpty(info: [*c]const stbtt_fontinfo, glyph_index: c_int) c_int;
pub extern fn stbtt_GetCodepointShape(info: [*c]const stbtt_fontinfo, unicode_codepoint: c_int, vertices: [*c][*c]stbtt_vertex) c_int;
pub extern fn stbtt_GetGlyphShape(info: [*c]const stbtt_fontinfo, glyph_index: c_int, vertices: [*c][*c]stbtt_vertex) c_int;
pub extern fn stbtt_FreeShape(info: [*c]const stbtt_fontinfo, vertices: [*c]stbtt_vertex) void;
pub extern fn stbtt_FindSVGDoc(info: [*c]const stbtt_fontinfo, gl: c_int) [*c]u8;
pub extern fn stbtt_GetCodepointSVG(info: [*c]const stbtt_fontinfo, unicode_codepoint: c_int, svg: [*c][*c]const u8) c_int;
pub extern fn stbtt_GetGlyphSVG(info: [*c]const stbtt_fontinfo, gl: c_int, svg: [*c][*c]const u8) c_int;
pub extern fn stbtt_FreeBitmap(bitmap: [*c]u8, userdata: ?*anyopaque) void;
pub extern fn stbtt_GetCodepointBitmap(info: [*c]const stbtt_fontinfo, scale_x: f32, scale_y: f32, codepoint: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_GetCodepointBitmapSubpixel(info: [*c]const stbtt_fontinfo, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, codepoint: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_MakeCodepointBitmap(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) void;
pub extern fn stbtt_MakeCodepointBitmapSubpixel(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, codepoint: c_int) void;
pub extern fn stbtt_MakeCodepointBitmapSubpixelPrefilter(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, oversample_x: c_int, oversample_y: c_int, sub_x: [*c]f32, sub_y: [*c]f32, codepoint: c_int) void;
pub extern fn stbtt_GetCodepointBitmapBox(font: [*c]const stbtt_fontinfo, codepoint: c_int, scale_x: f32, scale_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub extern fn stbtt_GetCodepointBitmapBoxSubpixel(font: [*c]const stbtt_fontinfo, codepoint: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub extern fn stbtt_GetGlyphBitmap(info: [*c]const stbtt_fontinfo, scale_x: f32, scale_y: f32, glyph: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_GetGlyphBitmapSubpixel(info: [*c]const stbtt_fontinfo, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, glyph: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_MakeGlyphBitmap(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, glyph: c_int) void;
pub extern fn stbtt_MakeGlyphBitmapSubpixel(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, glyph: c_int) void;
pub extern fn stbtt_MakeGlyphBitmapSubpixelPrefilter(info: [*c]const stbtt_fontinfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, oversample_x: c_int, oversample_y: c_int, sub_x: [*c]f32, sub_y: [*c]f32, glyph: c_int) void;
pub extern fn stbtt_GetGlyphBitmapBox(font: [*c]const stbtt_fontinfo, glyph: c_int, scale_x: f32, scale_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub extern fn stbtt_GetGlyphBitmapBoxSubpixel(font: [*c]const stbtt_fontinfo, glyph: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub const stbtt__bitmap = extern struct {
    w: c_int = 0,
    h: c_int = 0,
    stride: c_int = 0,
    pixels: [*c]u8 = null,
    pub const stbtt_Rasterize = __root.stbtt_Rasterize;
    pub const Rasterize = __root.stbtt_Rasterize;
};
pub extern fn stbtt_Rasterize(result: [*c]stbtt__bitmap, flatness_in_pixels: f32, vertices: [*c]stbtt_vertex, num_verts: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, x_off: c_int, y_off: c_int, invert: c_int, userdata: ?*anyopaque) void;
pub extern fn stbtt_FreeSDF(bitmap: [*c]u8, userdata: ?*anyopaque) void;
pub extern fn stbtt_GetGlyphSDF(info: [*c]const stbtt_fontinfo, scale: f32, glyph: c_int, padding: c_int, onedge_value: u8, pixel_dist_scale: f32, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_GetCodepointSDF(info: [*c]const stbtt_fontinfo, scale: f32, codepoint: c_int, padding: c_int, onedge_value: u8, pixel_dist_scale: f32, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub extern fn stbtt_FindMatchingFont(fontdata: [*c]const u8, name: [*c]const u8, flags: c_int) c_int;
pub extern fn stbtt_CompareUTF8toUTF16_bigendian(s1: [*c]const u8, len1: c_int, s2: [*c]const u8, len2: c_int) c_int;
pub extern fn stbtt_GetFontNameString(font: [*c]const stbtt_fontinfo, length: [*c]c_int, platformID: c_int, encodingID: c_int, languageID: c_int, nameID: c_int) [*c]const u8;
pub const STBTT_PLATFORM_ID_UNICODE: c_int = 0;
pub const STBTT_PLATFORM_ID_MAC: c_int = 1;
pub const STBTT_PLATFORM_ID_ISO: c_int = 2;
pub const STBTT_PLATFORM_ID_MICROSOFT: c_int = 3;
const enum_unnamed_2 = c_uint;
pub const STBTT_UNICODE_EID_UNICODE_1_0: c_int = 0;
pub const STBTT_UNICODE_EID_UNICODE_1_1: c_int = 1;
pub const STBTT_UNICODE_EID_ISO_10646: c_int = 2;
pub const STBTT_UNICODE_EID_UNICODE_2_0_BMP: c_int = 3;
pub const STBTT_UNICODE_EID_UNICODE_2_0_FULL: c_int = 4;
const enum_unnamed_3 = c_uint;
pub const STBTT_MS_EID_SYMBOL: c_int = 0;
pub const STBTT_MS_EID_UNICODE_BMP: c_int = 1;
pub const STBTT_MS_EID_SHIFTJIS: c_int = 2;
pub const STBTT_MS_EID_UNICODE_FULL: c_int = 10;
const enum_unnamed_4 = c_uint;
pub const STBTT_MAC_EID_ROMAN: c_int = 0;
pub const STBTT_MAC_EID_ARABIC: c_int = 4;
pub const STBTT_MAC_EID_JAPANESE: c_int = 1;
pub const STBTT_MAC_EID_HEBREW: c_int = 5;
pub const STBTT_MAC_EID_CHINESE_TRAD: c_int = 2;
pub const STBTT_MAC_EID_GREEK: c_int = 6;
pub const STBTT_MAC_EID_KOREAN: c_int = 3;
pub const STBTT_MAC_EID_RUSSIAN: c_int = 7;
const enum_unnamed_5 = c_uint;
pub const STBTT_MS_LANG_ENGLISH: c_int = 1033;
pub const STBTT_MS_LANG_ITALIAN: c_int = 1040;
pub const STBTT_MS_LANG_CHINESE: c_int = 2052;
pub const STBTT_MS_LANG_JAPANESE: c_int = 1041;
pub const STBTT_MS_LANG_DUTCH: c_int = 1043;
pub const STBTT_MS_LANG_KOREAN: c_int = 1042;
pub const STBTT_MS_LANG_FRENCH: c_int = 1036;
pub const STBTT_MS_LANG_RUSSIAN: c_int = 1049;
pub const STBTT_MS_LANG_GERMAN: c_int = 1031;
pub const STBTT_MS_LANG_SPANISH: c_int = 1033;
pub const STBTT_MS_LANG_HEBREW: c_int = 1037;
pub const STBTT_MS_LANG_SWEDISH: c_int = 1053;
const enum_unnamed_6 = c_uint;
pub const STBTT_MAC_LANG_ENGLISH: c_int = 0;
pub const STBTT_MAC_LANG_JAPANESE: c_int = 11;
pub const STBTT_MAC_LANG_ARABIC: c_int = 12;
pub const STBTT_MAC_LANG_KOREAN: c_int = 23;
pub const STBTT_MAC_LANG_DUTCH: c_int = 4;
pub const STBTT_MAC_LANG_RUSSIAN: c_int = 32;
pub const STBTT_MAC_LANG_FRENCH: c_int = 1;
pub const STBTT_MAC_LANG_SPANISH: c_int = 6;
pub const STBTT_MAC_LANG_GERMAN: c_int = 2;
pub const STBTT_MAC_LANG_SWEDISH: c_int = 5;
pub const STBTT_MAC_LANG_HEBREW: c_int = 10;
pub const STBTT_MAC_LANG_CHINESE_SIMPLIFIED: c_int = 33;
pub const STBTT_MAC_LANG_ITALIAN: c_int = 3;
pub const STBTT_MAC_LANG_CHINESE_TRAD: c_int = 19;
const enum_unnamed_7 = c_uint;

pub const __VERSION__ = "Aro aro-zig";
pub const __Aro__ = "";
pub const __STDC__ = @as(c_int, 1);
pub const __STDC_HOSTED__ = @as(c_int, 1);
pub const __STDC_UTF_16__ = @as(c_int, 1);
pub const __STDC_UTF_32__ = @as(c_int, 1);
pub const __STDC_EMBED_NOT_FOUND__ = @as(c_int, 0);
pub const __STDC_EMBED_FOUND__ = @as(c_int, 1);
pub const __STDC_EMBED_EMPTY__ = @as(c_int, 2);
pub const __STDC_VERSION__ = @as(c_long, 201710);
pub const __GNUC__ = @as(c_int, 7);
pub const __GNUC_MINOR__ = @as(c_int, 1);
pub const __GNUC_PATCHLEVEL__ = @as(c_int, 0);
pub const __ARO_EMULATE_NO__ = @as(c_int, 0);
pub const __ARO_EMULATE_CLANG__ = @as(c_int, 1);
pub const __ARO_EMULATE_GCC__ = @as(c_int, 2);
pub const __ARO_EMULATE_MSVC__ = @as(c_int, 3);
pub const __ARO_EMULATE__ = __ARO_EMULATE_GCC__;
pub inline fn __building_module(x: anytype) @TypeOf(@as(c_int, 0)) {
    _ = &x;
    return @as(c_int, 0);
}
pub const _WIN32 = @as(c_int, 1);
pub const _WIN64 = @as(c_int, 1);
pub const WIN32 = @as(c_int, 1);
pub const __WIN32 = @as(c_int, 1);
pub const __WIN32__ = @as(c_int, 1);
pub const WINNT = @as(c_int, 1);
pub const __WINNT = @as(c_int, 1);
pub const __WINNT__ = @as(c_int, 1);
pub const WIN64 = @as(c_int, 1);
pub const __WIN64 = @as(c_int, 1);
pub const __WIN64__ = @as(c_int, 1);
pub const __MINGW64__ = @as(c_int, 1);
pub const __MSVCRT__ = @as(c_int, 1);
pub const __MINGW32__ = @as(c_int, 1);
pub const __declspec = @compileError("unable to translate C expr: unexpected token '__attribute__'");
// <builtin>:34:9
pub const _cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// <builtin>:35:9
pub const __cdecl = @compileError("unable to translate macro: undefined identifier `__cdecl__`");
// <builtin>:36:9
pub const _stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// <builtin>:37:9
pub const __stdcall = @compileError("unable to translate macro: undefined identifier `__stdcall__`");
// <builtin>:38:9
pub const _fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// <builtin>:39:9
pub const __fastcall = @compileError("unable to translate macro: undefined identifier `__fastcall__`");
// <builtin>:40:9
pub const _thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// <builtin>:41:9
pub const __thiscall = @compileError("unable to translate macro: undefined identifier `__thiscall__`");
// <builtin>:42:9
pub const __code_model_small__ = @as(c_int, 1);
pub const __amd64__ = @as(c_int, 1);
pub const __amd64 = @as(c_int, 1);
pub const __x86_64__ = @as(c_int, 1);
pub const __x86_64 = @as(c_int, 1);
pub const __SEG_GS = @as(c_int, 1);
pub const __SEG_FS = @as(c_int, 1);
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:50:9
pub const __seg_fs = @compileError("unable to translate macro: undefined identifier `address_space`");
// <builtin>:51:9
pub const __LAHF_SAHF__ = @as(c_int, 1);
pub const __AES__ = @as(c_int, 1);
pub const __VAES__ = @as(c_int, 1);
pub const __PCLMUL__ = @as(c_int, 1);
pub const __VPCLMULQDQ__ = @as(c_int, 1);
pub const __LZCNT__ = @as(c_int, 1);
pub const __RDRND__ = @as(c_int, 1);
pub const __FSGSBASE__ = @as(c_int, 1);
pub const __BMI__ = @as(c_int, 1);
pub const __BMI2__ = @as(c_int, 1);
pub const __POPCNT__ = @as(c_int, 1);
pub const __PRFCHW__ = @as(c_int, 1);
pub const __RDSEED__ = @as(c_int, 1);
pub const __ADX__ = @as(c_int, 1);
pub const __MWAITX__ = @as(c_int, 1);
pub const __MOVBE__ = @as(c_int, 1);
pub const __SSE4A__ = @as(c_int, 1);
pub const __FMA__ = @as(c_int, 1);
pub const __F16C__ = @as(c_int, 1);
pub const __GFNI__ = @as(c_int, 1);
pub const __AVX512CD__ = @as(c_int, 1);
pub const __AVX512VPOPCNTDQ__ = @as(c_int, 1);
pub const __AVX512VNNI__ = @as(c_int, 1);
pub const __AVX512BF16__ = @as(c_int, 1);
pub const __AVX512DQ__ = @as(c_int, 1);
pub const __AVX512BITALG__ = @as(c_int, 1);
pub const __AVX512BW__ = @as(c_int, 1);
pub const __AVX512VL__ = @as(c_int, 1);
pub const __EVEX256__ = @as(c_int, 1);
pub const __AVX512VBMI__ = @as(c_int, 1);
pub const __AVX512VBMI2__ = @as(c_int, 1);
pub const __AVX512IFMA__ = @as(c_int, 1);
pub const __SHA__ = @as(c_int, 1);
pub const __FXSR__ = @as(c_int, 1);
pub const __XSAVE__ = @as(c_int, 1);
pub const __XSAVEOPT__ = @as(c_int, 1);
pub const __XSAVEC__ = @as(c_int, 1);
pub const __XSAVES__ = @as(c_int, 1);
pub const __CLFLUSHOPT__ = @as(c_int, 1);
pub const __CLWB__ = @as(c_int, 1);
pub const __WBNOINVD__ = @as(c_int, 1);
pub const __SHSTK__ = @as(c_int, 1);
pub const __CLZERO__ = @as(c_int, 1);
pub const __RDPID__ = @as(c_int, 1);
pub const __RDPRU__ = @as(c_int, 1);
pub const __INVPCID__ = @as(c_int, 1);
pub const __CRC32__ = @as(c_int, 1);
pub const __AVX512F__ = @as(c_int, 1);
pub const __AVX2__ = @as(c_int, 1);
pub const __AVX__ = @as(c_int, 1);
pub const __SSE4_2__ = @as(c_int, 1);
pub const __SSE4_1__ = @as(c_int, 1);
pub const __SSSE3__ = @as(c_int, 1);
pub const __SSE3__ = @as(c_int, 1);
pub const __SSE2__ = @as(c_int, 1);
pub const __SSE__ = @as(c_int, 1);
pub const __SSE_MATH__ = @as(c_int, 1);
pub const __MMX__ = @as(c_int, 1);
pub const __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8 = @as(c_int, 1);
pub const __ORDER_LITTLE_ENDIAN__ = @as(c_int, 1234);
pub const __ORDER_BIG_ENDIAN__ = @as(c_int, 4321);
pub const __ORDER_PDP_ENDIAN__ = @as(c_int, 3412);
pub const __BYTE_ORDER__ = __ORDER_LITTLE_ENDIAN__;
pub const __LITTLE_ENDIAN__ = @as(c_int, 1);
pub const __ATOMIC_RELAXED = @as(c_int, 0);
pub const __ATOMIC_CONSUME = @as(c_int, 1);
pub const __ATOMIC_ACQUIRE = @as(c_int, 2);
pub const __ATOMIC_RELEASE = @as(c_int, 3);
pub const __ATOMIC_ACQ_REL = @as(c_int, 4);
pub const __ATOMIC_SEQ_CST = @as(c_int, 5);
pub const __ATOMIC_BOOL_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR16_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_CHAR32_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WCHAR_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_WINT_T_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_SHORT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_INT_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_LLONG_LOCK_FREE = @as(c_int, 1);
pub const __ATOMIC_POINTER_LOCK_FREE = @as(c_int, 1);
pub const __WCHAR_UNSIGNED__ = @as(c_int, 1);
pub const __WINT_UNSIGNED__ = @as(c_int, 1);
pub const __CHAR_BIT__ = @as(c_int, 8);
pub const __BOOL_WIDTH__ = @as(c_int, 8);
pub const __SCHAR_MAX__ = @as(c_int, 127);
pub const __SCHAR_WIDTH__ = @as(c_int, 8);
pub const __SHRT_MAX__ = @as(c_int, 32767);
pub const __SHRT_WIDTH__ = @as(c_int, 16);
pub const __INT_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_WIDTH__ = @as(c_int, 32);
pub const __LONG_MAX__ = @as(c_long, 2147483647);
pub const __LONG_WIDTH__ = @as(c_int, 32);
pub const __LONG_LONG_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __LONG_LONG_WIDTH__ = @as(c_int, 64);
pub const __WCHAR_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WCHAR_WIDTH__ = @as(c_int, 16);
pub const __WINT_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __WINT_WIDTH__ = @as(c_int, 16);
pub const __INTMAX_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTMAX_WIDTH__ = @as(c_int, 64);
pub const __SIZE_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __SIZE_WIDTH__ = @as(c_int, 64);
pub const __UINTMAX_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTMAX_WIDTH__ = @as(c_int, 64);
pub const __PTRDIFF_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __PTRDIFF_WIDTH__ = @as(c_int, 64);
pub const __INTPTR_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INTPTR_WIDTH__ = @as(c_int, 64);
pub const __UINTPTR_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __UINTPTR_WIDTH__ = @as(c_int, 64);
pub const __SIG_ATOMIC_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __SIG_ATOMIC_WIDTH__ = @as(c_int, 32);
pub const __BITINT_MAXWIDTH__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __SIZEOF_FLOAT__ = @as(c_int, 4);
pub const __SIZEOF_DOUBLE__ = @as(c_int, 8);
pub const __SIZEOF_LONG_DOUBLE__ = @as(c_int, 10);
pub const __SIZEOF_SHORT__ = @as(c_int, 2);
pub const __SIZEOF_INT__ = @as(c_int, 4);
pub const __SIZEOF_LONG__ = @as(c_int, 4);
pub const __SIZEOF_LONG_LONG__ = @as(c_int, 8);
pub const __SIZEOF_POINTER__ = @as(c_int, 8);
pub const __SIZEOF_PTRDIFF_T__ = @as(c_int, 8);
pub const __SIZEOF_SIZE_T__ = @as(c_int, 8);
pub const __SIZEOF_WCHAR_T__ = @as(c_int, 2);
pub const __SIZEOF_WINT_T__ = @as(c_int, 2);
pub const __SIZEOF_INT128__ = @as(c_int, 16);
pub const __INTPTR_TYPE__ = c_longlong;
pub const __UINTPTR_TYPE__ = c_ulonglong;
pub const __INTMAX_TYPE__ = c_longlong;
pub const __INTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// <builtin>:183:9
pub const __INTMAX_C = __helpers.LL_SUFFIX;
pub const __UINTMAX_TYPE__ = c_ulonglong;
pub const __UINTMAX_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// <builtin>:186:9
pub const __UINTMAX_C = __helpers.ULL_SUFFIX;
pub const __PTRDIFF_TYPE__ = c_longlong;
pub const __SIZE_TYPE__ = c_ulonglong;
pub const __WCHAR_TYPE__ = c_ushort;
pub const __WINT_TYPE__ = c_ushort;
pub const __CHAR16_TYPE__ = c_ushort;
pub const __CHAR32_TYPE__ = c_uint;
pub const __INT8_TYPE__ = i8;
pub const __INT8_FMTd__ = "hhd";
pub const __INT8_FMTi__ = "hhi";
pub const __INT8_C_SUFFIX__ = "";
pub inline fn __INT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT16_TYPE__ = c_short;
pub const __INT16_FMTd__ = "hd";
pub const __INT16_FMTi__ = "hi";
pub const __INT16_C_SUFFIX__ = "";
pub inline fn __INT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT32_TYPE__ = c_int;
pub const __INT32_FMTd__ = "d";
pub const __INT32_FMTi__ = "i";
pub const __INT32_C_SUFFIX__ = "";
pub inline fn __INT32_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __INT64_TYPE__ = c_longlong;
pub const __INT64_FMTd__ = "lld";
pub const __INT64_FMTi__ = "lli";
pub const __INT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `LL`");
// <builtin>:212:9
pub const __INT64_C = __helpers.LL_SUFFIX;
pub const __UINT8_TYPE__ = u8;
pub const __UINT8_FMTo__ = "hho";
pub const __UINT8_FMTu__ = "hhu";
pub const __UINT8_FMTx__ = "hhx";
pub const __UINT8_FMTX__ = "hhX";
pub const __UINT8_C_SUFFIX__ = "";
pub inline fn __UINT8_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT8_MAX__ = @as(c_int, 255);
pub const __INT8_MAX__ = @as(c_int, 127);
pub const __UINT16_TYPE__ = c_ushort;
pub const __UINT16_FMTo__ = "ho";
pub const __UINT16_FMTu__ = "hu";
pub const __UINT16_FMTx__ = "hx";
pub const __UINT16_FMTX__ = "hX";
pub const __UINT16_C_SUFFIX__ = "";
pub inline fn __UINT16_C(c: anytype) @TypeOf(c) {
    _ = &c;
    return c;
}
pub const __UINT16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const __INT16_MAX__ = @as(c_int, 32767);
pub const __UINT32_TYPE__ = c_uint;
pub const __UINT32_FMTo__ = "o";
pub const __UINT32_FMTu__ = "u";
pub const __UINT32_FMTx__ = "x";
pub const __UINT32_FMTX__ = "X";
pub const __UINT32_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `U`");
// <builtin>:237:9
pub const __UINT32_C = __helpers.U_SUFFIX;
pub const __UINT32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const __INT32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __UINT64_TYPE__ = c_ulonglong;
pub const __UINT64_FMTo__ = "llo";
pub const __UINT64_FMTu__ = "llu";
pub const __UINT64_FMTx__ = "llx";
pub const __UINT64_FMTX__ = "llX";
pub const __UINT64_C_SUFFIX__ = @compileError("unable to translate macro: undefined identifier `ULL`");
// <builtin>:246:9
pub const __UINT64_C = __helpers.ULL_SUFFIX;
pub const __UINT64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const __INT64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST8_TYPE__ = i8;
pub const __INT_LEAST8_MAX__ = @as(c_int, 127);
pub const __INT_LEAST8_WIDTH__ = @as(c_int, 8);
pub const INT_LEAST8_FMTd__ = "hhd";
pub const INT_LEAST8_FMTi__ = "hhi";
pub const __UINT_LEAST8_TYPE__ = u8;
pub const __UINT_LEAST8_MAX__ = @as(c_int, 255);
pub const UINT_LEAST8_FMTo__ = "hho";
pub const UINT_LEAST8_FMTu__ = "hhu";
pub const UINT_LEAST8_FMTx__ = "hhx";
pub const UINT_LEAST8_FMTX__ = "hhX";
pub const __INT_FAST8_TYPE__ = i8;
pub const __INT_FAST8_MAX__ = @as(c_int, 127);
pub const __INT_FAST8_WIDTH__ = @as(c_int, 8);
pub const INT_FAST8_FMTd__ = "hhd";
pub const INT_FAST8_FMTi__ = "hhi";
pub const __UINT_FAST8_TYPE__ = u8;
pub const __UINT_FAST8_MAX__ = @as(c_int, 255);
pub const UINT_FAST8_FMTo__ = "hho";
pub const UINT_FAST8_FMTu__ = "hhu";
pub const UINT_FAST8_FMTx__ = "hhx";
pub const UINT_FAST8_FMTX__ = "hhX";
pub const __INT_LEAST16_TYPE__ = c_short;
pub const __INT_LEAST16_MAX__ = @as(c_int, 32767);
pub const __INT_LEAST16_WIDTH__ = @as(c_int, 16);
pub const INT_LEAST16_FMTd__ = "hd";
pub const INT_LEAST16_FMTi__ = "hi";
pub const __UINT_LEAST16_TYPE__ = c_ushort;
pub const __UINT_LEAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_LEAST16_FMTo__ = "ho";
pub const UINT_LEAST16_FMTu__ = "hu";
pub const UINT_LEAST16_FMTx__ = "hx";
pub const UINT_LEAST16_FMTX__ = "hX";
pub const __INT_FAST16_TYPE__ = c_short;
pub const __INT_FAST16_MAX__ = @as(c_int, 32767);
pub const __INT_FAST16_WIDTH__ = @as(c_int, 16);
pub const INT_FAST16_FMTd__ = "hd";
pub const INT_FAST16_FMTi__ = "hi";
pub const __UINT_FAST16_TYPE__ = c_ushort;
pub const __UINT_FAST16_MAX__ = __helpers.promoteIntLiteral(c_int, 65535, .decimal);
pub const UINT_FAST16_FMTo__ = "ho";
pub const UINT_FAST16_FMTu__ = "hu";
pub const UINT_FAST16_FMTx__ = "hx";
pub const UINT_FAST16_FMTX__ = "hX";
pub const __INT_LEAST32_TYPE__ = c_int;
pub const __INT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_LEAST32_WIDTH__ = @as(c_int, 32);
pub const INT_LEAST32_FMTd__ = "d";
pub const INT_LEAST32_FMTi__ = "i";
pub const __UINT_LEAST32_TYPE__ = c_uint;
pub const __UINT_LEAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_LEAST32_FMTo__ = "o";
pub const UINT_LEAST32_FMTu__ = "u";
pub const UINT_LEAST32_FMTx__ = "x";
pub const UINT_LEAST32_FMTX__ = "X";
pub const __INT_FAST32_TYPE__ = c_int;
pub const __INT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_int, 2147483647, .decimal);
pub const __INT_FAST32_WIDTH__ = @as(c_int, 32);
pub const INT_FAST32_FMTd__ = "d";
pub const INT_FAST32_FMTi__ = "i";
pub const __UINT_FAST32_TYPE__ = c_uint;
pub const __UINT_FAST32_MAX__ = __helpers.promoteIntLiteral(c_uint, 4294967295, .decimal);
pub const UINT_FAST32_FMTo__ = "o";
pub const UINT_FAST32_FMTu__ = "u";
pub const UINT_FAST32_FMTx__ = "x";
pub const UINT_FAST32_FMTX__ = "X";
pub const __INT_LEAST64_TYPE__ = c_longlong;
pub const __INT_LEAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_LEAST64_WIDTH__ = @as(c_int, 64);
pub const INT_LEAST64_FMTd__ = "lld";
pub const INT_LEAST64_FMTi__ = "lli";
pub const __UINT_LEAST64_TYPE__ = c_ulonglong;
pub const __UINT_LEAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_LEAST64_FMTo__ = "llo";
pub const UINT_LEAST64_FMTu__ = "llu";
pub const UINT_LEAST64_FMTx__ = "llx";
pub const UINT_LEAST64_FMTX__ = "llX";
pub const __INT_FAST64_TYPE__ = c_longlong;
pub const __INT_FAST64_MAX__ = @as(c_longlong, 9223372036854775807);
pub const __INT_FAST64_WIDTH__ = @as(c_int, 64);
pub const INT_FAST64_FMTd__ = "lld";
pub const INT_FAST64_FMTi__ = "lli";
pub const __UINT_FAST64_TYPE__ = c_ulonglong;
pub const __UINT_FAST64_MAX__ = @as(c_ulonglong, 18446744073709551615);
pub const UINT_FAST64_FMTo__ = "llo";
pub const UINT_FAST64_FMTu__ = "llu";
pub const UINT_FAST64_FMTx__ = "llx";
pub const UINT_FAST64_FMTX__ = "llX";
pub const __FLT16_DENORM_MIN__ = @as(f16, 5.9604644775390625e-8);
pub const __FLT16_HAS_DENORM__ = "";
pub const __FLT16_DIG__ = @as(c_int, 3);
pub const __FLT16_DECIMAL_DIG__ = @as(c_int, 5);
pub const __FLT16_EPSILON__ = @as(f16, 9.765625e-4);
pub const __FLT16_HAS_INFINITY__ = "";
pub const __FLT16_HAS_QUIET_NAN__ = "";
pub const __FLT16_MANT_DIG__ = @as(c_int, 11);
pub const __FLT16_MAX_10_EXP__ = @as(c_int, 4);
pub const __FLT16_MAX_EXP__ = @as(c_int, 16);
pub const __FLT16_MAX__ = @as(f16, 6.5504e+4);
pub const __FLT16_MIN_10_EXP__ = -@as(c_int, 4);
pub const __FLT16_MIN_EXP__ = -@as(c_int, 13);
pub const __FLT16_MIN__ = @as(f16, 6.103515625e-5);
pub const __FLT_DENORM_MIN__ = @as(f32, 1.40129846e-45);
pub const __FLT_HAS_DENORM__ = "";
pub const __FLT_DIG__ = @as(c_int, 6);
pub const __FLT_DECIMAL_DIG__ = @as(c_int, 9);
pub const __FLT_EPSILON__ = @as(f32, 1.19209290e-7);
pub const __FLT_HAS_INFINITY__ = "";
pub const __FLT_HAS_QUIET_NAN__ = "";
pub const __FLT_MANT_DIG__ = @as(c_int, 24);
pub const __FLT_MAX_10_EXP__ = @as(c_int, 38);
pub const __FLT_MAX_EXP__ = @as(c_int, 128);
pub const __FLT_MAX__ = @as(f32, 3.40282347e+38);
pub const __FLT_MIN_10_EXP__ = -@as(c_int, 37);
pub const __FLT_MIN_EXP__ = -@as(c_int, 125);
pub const __FLT_MIN__ = @as(f32, 1.17549435e-38);
pub const __DBL_DENORM_MIN__ = @as(f64, 4.9406564584124654e-324);
pub const __DBL_HAS_DENORM__ = "";
pub const __DBL_DIG__ = @as(c_int, 15);
pub const __DBL_DECIMAL_DIG__ = @as(c_int, 17);
pub const __DBL_EPSILON__ = @as(f64, 2.2204460492503131e-16);
pub const __DBL_HAS_INFINITY__ = "";
pub const __DBL_HAS_QUIET_NAN__ = "";
pub const __DBL_MANT_DIG__ = @as(c_int, 53);
pub const __DBL_MAX_10_EXP__ = @as(c_int, 308);
pub const __DBL_MAX_EXP__ = @as(c_int, 1024);
pub const __DBL_MAX__ = @as(f64, 1.7976931348623157e+308);
pub const __DBL_MIN_10_EXP__ = -@as(c_int, 307);
pub const __DBL_MIN_EXP__ = -@as(c_int, 1021);
pub const __DBL_MIN__ = @as(f64, 2.2250738585072014e-308);
pub const __LDBL_DENORM_MIN__ = @as(c_longdouble, 3.64519953188247460253e-4951);
pub const __LDBL_HAS_DENORM__ = "";
pub const __LDBL_DIG__ = @as(c_int, 18);
pub const __LDBL_DECIMAL_DIG__ = @as(c_int, 21);
pub const __LDBL_EPSILON__ = @as(c_longdouble, 1.08420217248550443401e-19);
pub const __LDBL_HAS_INFINITY__ = "";
pub const __LDBL_HAS_QUIET_NAN__ = "";
pub const __LDBL_MANT_DIG__ = @as(c_int, 64);
pub const __LDBL_MAX_10_EXP__ = @as(c_int, 4932);
pub const __LDBL_MAX_EXP__ = @as(c_int, 16384);
pub const __LDBL_MAX__ = @as(c_longdouble, 1.18973149535723176502e+4932);
pub const __LDBL_MIN_10_EXP__ = -@as(c_int, 4931);
pub const __LDBL_MIN_EXP__ = -@as(c_int, 16381);
pub const __LDBL_MIN__ = @as(c_longdouble, 3.36210314311209350626e-4932);
pub const __FLT_EVAL_METHOD__ = @as(c_int, 0);
pub const __FLT_RADIX__ = @as(c_int, 2);
pub const __DECIMAL_DIG__ = __LDBL_DECIMAL_DIG__;
pub const __pic__ = @as(c_int, 2);
pub const __PIC__ = @as(c_int, 2);
pub const __STB_INCLUDE_STB_TRUETYPE_H__ = "";
pub const STBTT_DEF = @compileError("unable to translate C expr: unexpected token 'extern'");
// libs\stb\stb_truetype.h:505:9
pub inline fn STBTT_POINT_SIZE(x: anytype) @TypeOf(-x) {
    _ = &x;
    return -x;
}
pub const stbtt_vertex_type = c_short;
pub const STBTT_MACSTYLE_DONTCARE = @as(c_int, 0);
pub const STBTT_MACSTYLE_BOLD = @as(c_int, 1);
pub const STBTT_MACSTYLE_ITALIC = @as(c_int, 2);
pub const STBTT_MACSTYLE_UNDERSCORE = @as(c_int, 4);
pub const STBTT_MACSTYLE_NONE = @as(c_int, 8);
