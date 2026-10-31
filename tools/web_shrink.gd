extends SceneTree

## Rewrites an exported pck so its mipmapped lossless WebP textures are lossy WebP.
##
##     godot --headless --path . --script res://tools/web_shrink.gd -- web/build/index.pck [quality]
##
## Mipmaps mark a 3D texture; UI art (no mipmaps) stays lossless, and VRAM-compressed
## textures are left alone. Desktop builds keep the addons' own import settings: only the
## browser pays for every byte on every new shell, so only export-web runs this.

const MAGIC := 0x43504447 # "GDPC"
const FLAG_REL_FILEBASE := 2
const ALIGN := 16
const CTEX_HEADER := 36
const DATA_FORMAT_WEBP := 2
const DEFAULT_QUALITY := 0.7


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("usage: web_shrink.gd -- <index.pck> [quality 0..1]")
		quit(2)
		return
	var quality := float(args[1]) if args.size() > 1 else DEFAULT_QUALITY
	quit(_shrink(args[0], quality))


func _shrink(path: String, quality: float) -> int:
	var src := FileAccess.open(path, FileAccess.READ)
	if src == null:
		printerr("web_shrink: cannot open %s" % path)
		return 1
	if src.get_32() != MAGIC:
		printerr("web_shrink: %s is not a pck" % path)
		return 1
	var version := src.get_32()
	src.seek(20)
	var flags := src.get_32()
	var file_base := src.get_64()
	var dir_offset := src.get_64()
	# v3 and v4 share this layout; encrypted or sparse packs do not.
	if version < 3 or version > 4 or flags != FLAG_REL_FILEBASE:
		printerr("web_shrink: pck version %d flags %d is not one this tool rewrites" % [version, flags])
		return 1
	src.seek(0)
	var header := src.get_buffer(file_base)

	src.seek(dir_offset)
	var count := src.get_32()
	var entries: Array[Dictionary] = []
	for i in count:
		var path_len := src.get_32()
		var raw_path := src.get_buffer(path_len)
		var offset := src.get_64()
		var size := src.get_64()
		src.get_buffer(16)
		var entry_flags := src.get_32()
		entries.append({"path": raw_path, "offset": offset, "size": size, "flags": entry_flags})

	var tmp_path := path + ".shrink"
	var dst := FileAccess.open(tmp_path, FileAccess.WRITE)
	if dst == null:
		printerr("web_shrink: cannot write %s" % tmp_path)
		return 1
	dst.store_buffer(header)
	var before := 0
	var after := 0
	var changed := 0
	for entry in entries:
		src.seek(file_base + entry.offset)
		var data := src.get_buffer(entry.size)
		if (entry.path as PackedByteArray).get_string_from_utf8().ends_with(".ctex"):
			var smaller := _lossy_ctex(data, quality)
			if not smaller.is_empty():
				before += data.size()
				after += smaller.size()
				changed += 1
				data = smaller
		var pad := (ALIGN - (dst.get_position() - file_base) % ALIGN) % ALIGN
		for p in pad:
			dst.store_8(0)
		entry.offset = dst.get_position() - file_base
		entry.size = data.size()
		var md5 := HashingContext.new()
		md5.start(HashingContext.HASH_MD5)
		md5.update(data)
		entry.md5 = md5.finish()
		dst.store_buffer(data)

	var new_dir := dst.get_position()
	dst.store_32(entries.size())
	for entry in entries:
		dst.store_32((entry.path as PackedByteArray).size())
		dst.store_buffer(entry.path)
		dst.store_64(entry.offset)
		dst.store_64(entry.size)
		dst.store_buffer(entry.md5)
		dst.store_32(entry.flags)
	dst.seek(32)
	dst.store_64(new_dir)
	dst.close()
	src.close()

	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		printerr("web_shrink: cannot replace %s: %s" % [path, error_string(err)])
		return 1
	print("web_shrink: %d textures lossy at %.2f, %.1f MB -> %.1f MB" % [changed, quality, before / 1e6, after / 1e6])
	return 0


## The ctex re-encoded, or empty when it is not a mipmapped WebP ctex or would not shrink.
func _lossy_ctex(data: PackedByteArray, quality: float) -> PackedByteArray:
	if data.size() < CTEX_HEADER + 16 or data.decode_u32(0) != 0x32545347: # "GST2"
		return PackedByteArray()
	if data.decode_u32(CTEX_HEADER) != DATA_FORMAT_WEBP:
		return PackedByteArray()
	var mipmaps := data.decode_u32(CTEX_HEADER + 8)
	if mipmaps == 0:
		return PackedByteArray()
	var out := data.slice(0, CTEX_HEADER + 16)
	var pos := CTEX_HEADER + 16
	for m in mipmaps + 1:
		var size := data.decode_u32(pos)
		var image := Image.new()
		if image.load_webp_from_buffer(data.slice(pos + 4, pos + 4 + size)) != OK:
			return PackedByteArray()
		pos += 4 + size
		var lossy := image.save_webp_to_buffer(true, quality)
		var size_bytes := PackedByteArray()
		size_bytes.resize(4)
		size_bytes.encode_u32(0, lossy.size())
		out.append_array(size_bytes)
		out.append_array(lossy)
	return out if out.size() < data.size() else PackedByteArray()
