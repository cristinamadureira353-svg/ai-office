class_name OfficeArt
extends RefCounted
## V2 贴图入口：同一个资源同时用于地图、角色与界面。

const ROOT := "res://assets/cozy_office/"
const CELL := 32.0
static var _paths: Dictionary = {}
static var _textures: Dictionary = {}
static var _material: ShaderMaterial

static func texture(id: String) -> Texture2D:
	if _paths.is_empty():
		var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(ROOT + "manifest.json"))
		for asset in manifest.get("assets", []):
			_paths[String(asset["id"])] = "res://" + String(asset["resource"])
	if not _textures.has(id):
		assert(_paths.has(id), "Unknown office art: " + id)
		_textures[id] = load(_paths[id]) as Texture2D
	return _textures[id]

static func clean_material() -> ShaderMaterial:
	if _material == null:
		var shader := Shader.new()
		# 保留默认 COLOR 中的 modulate，宕机角色才能正确变灰。
		shader.code = "shader_type canvas_item; void fragment(){if(texture(TEXTURE,UV).a<0.08){discard;}}"
		_material = ShaderMaterial.new()
		_material.shader = shader
	return _material

static func sprite(id: String, foot: Vector2, width: float) -> Sprite2D:
	var node := Sprite2D.new()
	node.texture = texture(id)
	node.centered = false
	node.offset = Vector2(-node.texture.get_width() * 0.5, -node.texture.get_height())
	node.scale = Vector2.ONE * width / node.texture.get_width()
	node.position = foot
	node.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	node.material = clean_material()
	return node

static func actor_rect(tex: Texture2D, height: float) -> Rect2:
	var wh := tex.get_size() * height / tex.get_height()
	return Rect2(Vector2(-wh.x * 0.5, -height), wh)

static func backend_port() -> int:
	if OS.has_feature("web"):
		return int(JavaScriptBridge.eval("window.location.port", true))
	var requested := OS.get_environment("AI_OFFICE_PORT")
	return int(requested) if requested.is_valid_int() and int(requested) > 0 and int(requested) < 65536 else 8850

static func api_base() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("window.location.origin", true))
	return "http://127.0.0.1:%d" % backend_port()
