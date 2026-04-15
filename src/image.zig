//! PNG image encoder.
//!
//! Encodes raw RGBA8 pixel data as a PNG file using Zig's standard library
//! zlib deflate compressor. No external dependencies.

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

    // Compress with zlib
    var compressed = std.ArrayList(u8).init(alloc);
    defer compressed.deinit();
    var compress = try std.compress.zlib.compressor(compressed.writer(), .{});
    try compress.writer().writeAll(filtered);
    try compress.finish();

    try writeChunk(writer, "IDAT", compressed.items);
}

fn writeIend(writer: anytype) !void {
    try writeChunk(writer, "IEND", &.{});
}
