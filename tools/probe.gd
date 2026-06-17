extends SceneTree
var f := 0
var w
func _initialize() -> void:
	w = load("res://main.tscn").instantiate()
	get_root().add_child(w)
func _process(_d: float) -> bool:
	f += 1
	if f == 20:
		var trunks := 0
		var crowns := 0
		for n in get_root().find_children("*", "MeshInstance3D", true, false):
			if n.mesh is CylinderMesh:
				trunks += 1
			elif n.mesh is SphereMesh:
				crowns += 1
		printerr("TRUNKS=%d CROWNS=%d" % [trunks, crowns])
		return true
	return false
