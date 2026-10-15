extends SceneTree
## V2 正式界面资源入口和可缩放面板验证。
var passed := 0
var failed := 0
func check(label: String, good: bool) -> void:
	if good: passed += 1
	else: failed += 1
	print("PASS " if good else "FAIL ",label)
func _init() -> void:
	call_deferred("run")
func run() -> void:
	var ids := ["panel","dialogue_bubble","button_normal","button_hover","button_pressed","button_close","progress_track","progress_fill","icon_money","icon_time","icon_reputation","icon_mood","icon_stamina","icon_fatigue","icon_client","icon_fame"]
	for id in ids:
		check(id+" 可加载",OfficeArt.texture(id) is AtlasTexture)
	var panel := UITheme.skin("panel")
	check("九宫格边框不重复拉伸",panel.texture_margin_left == 42 and panel.texture_margin_top == 42)
	var normal := OfficeArt.texture("button_normal") as AtlasTexture
	var hover := OfficeArt.texture("button_hover") as AtlasTexture
	var pressed := OfficeArt.texture("button_pressed") as AtlasTexture
	check("三态按钮引用三个不同画面",normal.region != hover.region and hover.region != pressed.region)
	var host := Control.new()
	root.add_child(host)
	for wh in [Vector2(200,120),Vector2(420,44),Vector2(720,420)]:
		var box := NinePatchRect.new()
		box.texture = panel.texture
		box.size = wh
		host.add_child(box)
		await process_frame
		check("面板拉伸 "+str(wh),box.size == wh)
		box.queue_free()
	for who in ["m3","flash","longcat","kimi","step5"]:
		check(who+" 新头像",OfficeArt.texture(who+"_portrait") is AtlasTexture)
	host.queue_free()
	await process_frame
	print("UI ASSETS V2: ",passed," passed, ",failed," failed")
	quit(0 if failed == 0 else 1)
