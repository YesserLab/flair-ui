//! PNG image encoder.
//!
//! Encodes raw RGBA8 pixel data as a PNG file.  The IDAT payload uses a
//! hand-rolled zlib/DEFLATE-stored stream so there is no dependency on
//! std.compress (whose API changed substantially in Zig 0.15+).

const std = @import("std");

/// Write a PNG file containing `width × height` RGBA8 pixels.
///
/// `pixels` must be `width * height * 4` bytes, with rows in top-to-bottom
/// order and pixels in RGBA order.
pub fn writePng(
    writer: anytype,
    width: u32,
    height: u32,
    pixels: []const u8,
) !void {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);

    // PNG signature
    try writer.writeAll(&png_signature);

    // IHDR chunk
    try writeIhdr(writer, width, height);

    // IDAT chunk
    try writeIdat(writer, width, height, pixels);

    // IEND chunk
    try writeIend(writer);
}

/// Encode to a byte slice. Caller owns the returned memory.
pub fn encodePng(allocator: std.mem.Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    try writePng(buf.writer(), width, height, pixels);
    return buf.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

fn crc32(data: []const u8) u32 {
    return std.hash.Crc32.hash(data);
}

fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    // Length (4 bytes, big-endian)
    try writer.writeInt(u32, @intCast(data.len), .big);

    // Type + data + CRC
    const type_slice: []const u8 = chunk_type[0..4];
    var crc_hasher = std.hash.Crc32.init();
    crc_hasher.update(type_slice);
    crc_hasher.update(data);
    const crc = crc_hasher.final();

    try writer.writeAll(type_slice);
    try writer.writeAll(data);
    try writer.writeInt(u32, crc, .big);
}

fn writeIhdr(writer: anytype, width: u32, height: u32) !void {
    // IHDR is exactly 13 bytes:
    //   4 bytes width, 4 bytes height, 1 byte bit depth, 1 byte color type,
    //   1 byte compression, 1 byte filter method, 1 byte interlace method
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;  // bit depth: 8 bits per channel
    ihdr[9] = 6;  // color type 6 = RGBA
    ihdr[10] = 0; // compression method 0 (deflate)
    ihdr[11] = 0; // filter method 0
    ihdr[12] = 0; // interlace method 0 (no interlace)
    try writeChunk(writer, "IHDR", &ihdr);
}

fn writeIdat(writer: anytype, width: u32, height: u32, pixels: []const u8) !void {
    // We need to filter the scanlines (PNG filter type 0 = None) then compress.
    // Filtered data: each row is prefixed with a 1-byte filter type.

    // Allocate filtered data buffer
    const row_stride = @as(usize, width) * 4;
    const filtered_size = (row_stride + 1) * height;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const filtered = try alloc.alloc(u8, filtered_size);
    var dst_off: usize = 0;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        filtered[dst_off] = 0; // filter type: None
        dst_off += 1;
        const src_off = @as(usize, y) * row_stride;
        @memcpy(filtered[dst_off..][0..row_stride], pixels[src_off..][0..row_stride]);
        dst_off += row_stride;
    }

    // Compress with zlib (DEFLATE stored blocks — no LZ compression, always valid PNG).
    // std.compress.zlib was removed in Zig 0.15; we encode the zlib container manually.
    const compressed = try zlibStoreCompress(alloc, filtered);
    try writeChunk(writer, "IDAT", compressed);
}

/// Encode `data` as a zlib stream (RFC 1950) using DEFLATE stored blocks (RFC 1951 §3.2.4).
/// Stored blocks carry raw data with no compression, which is always legal in PNG IDAT.
fn zlibStoreCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();

    // Zlib header: CMF=0x78 (CM=8 deflate, CINFO=7 → 32 KiB window),
    // FLG=0x01 (FLEVEL=0 fastest, FDICT=0, FCHECK=1 so that 0x7801 % 31 == 0).
    try out.appendSlice(&[_]u8{ 0x78, 0x01 });

    // DEFLATE stored blocks: each up to 65535 bytes.
    var offset: usize = 0;
    while (true) {
        const remaining = data.len - offset;
        const block_len = @min(remaining, @as(usize, 0xFFFF));
        const is_final = (offset + block_len >= data.len);

        // Block header: BFINAL (bit 0) + BTYPE=00 (bits 1-2) stored in one byte.
        var block_hdr: [5]u8 = undefined;
        block_hdr[0] = if (is_final) 0x01 else 0x00;
        const blen: u16 = @intCast(block_len);
        std.mem.writeInt(u16, block_hdr[1..3], blen, .little);
        std.mem.writeInt(u16, block_hdr[3..5], ~blen, .little); // NLEN = one's complement
        try out.appendSlice(&block_hdr);
        try out.appendSlice(data[offset..][0..block_len]);

        offset += block_len;
        if (is_final) break;
    }

    // Adler-32 checksum of the uncompressed data, big-endian (RFC 1950 §2.2).
    var hasher = std.hash.Adler32.init();
    hasher.update(data);
    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, hasher.final(), .big);
    try out.appendSlice(&footer);

    return out.toOwnedSlice();
}

fn writeIend(writer: anytype) !void {
    try writeChunk(writer, "IEND", &.{});
}
