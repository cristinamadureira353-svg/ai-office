class_name ChiefDesk
extends Node2D
## Chief 的主管位：会议室主桌的一头。
##
## Chief 不占工位、不占并行执行位——它只是在会议桌一头有个自己的位置，
## 上面写着它的名字和「总管」。空着的桌子说明这个位置有人管，但人不在画面里。

var title := "Chief"
var subtitle := "总管"

const COL := Color("#7DC6FF")


func _draw() -> void:
	# 双圈的桌面：外圈实线是桌子，内圈虚一点的是它管事的范围。
	var center := Vector2(0, -10)
	draw_circle(center, 26.0, Color(0.09, 0.11, 0.16, 0.55))
	draw_arc(center, 26.0, 0.0, TAU, 40, Color(COL, 0.85), 2.0)
	draw_arc(center, 18.0, 0.0, TAU, 32, Color(COL, 0.28), 1.0)
	var font := ThemeDB.fallback_font
	UITheme.world_label(self, font, Vector2(0, -44), "%s · %s" % [title, subtitle], 14, COL)
