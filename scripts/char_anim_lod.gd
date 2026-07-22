class_name CharAnimLod
extends RefCounted
## 角色动画 LOD:按到玩家的距离,把最近 N 个角色升到「高保真档」(24fps 图集),其余维持
## 底座(8fps 图集,现状)。高保真图集由本管理器**强引用持有**——一旦某角色跌出最近 N 集,
## 丢掉这个引用;若无他处引用,GPU 显存即被回收(机制见 spike:丢最后引用→显存回落实测)。
##
## 为什么按距离而非对话:现有 video-hero(world._begin_video_heroes)按对话事件把焦点角色升
## 24fps 真视频,受解码限 ≤1-2 路。本管理器按距离连续选 N 个升 24fps 图集——图集无解码开销,
## N 可更大(显存增量 N×(11.4-3.81)MB),用来替/补那套视频 LOD。docs/video-hero-lod-design.md。
##
## 职责单一:只决定「谁在高保真集」+ 持有高保真纹理引用。真正的异步拉图集、play_anim 切档由
## 调用方(world)按本管理器返回的 enter/leave 执行——好让本类保持纯逻辑、可 headless 单测。

const DEFAULT_MAX_HI := 3  ## 高保真池上限 N(显存×帧率的权衡;骨架期默认值,接入后按平板实测调)

var max_hi := DEFAULT_MAX_HI

## 当前高保真集:char_id → 持有的高保真 Texture2D 强引用。
## enter 时先占 null(防 fetch 未回时被重复 enter),hold() 再填真纹理。
var _hi: Dictionary = {}

## 喂入本帧世界状态,返回本次的档位变化,调用方据此拉图集/切档。
## chars: Array[{ id:String, dist:float }]——dist 是到玩家的距离(调用方用环面距离算好)。
## 返回 { enter:[id...], leave:[id...] }。enter 的 id 已在 _hi 里占位(值 null),
## 调用方拉到高保真图集后调 hold(id, tex) 填引用;leave 的 id 已从 _hi 移除(引用已丢)。
func update(chars: Array) -> Dictionary:
	var sorted := chars.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("dist", INF)) < float(b.get("dist", INF)))
	var want := {}
	for i in mini(max_hi, sorted.size()):
		var id := String((sorted[i] as Dictionary).get("id", ""))
		if not id.is_empty():
			want[id] = true
	var enter: Array = []
	var leave: Array = []
	for id in want:
		if not _hi.has(id):
			enter.append(id)
			_hi[id] = null  # 占位:防同一 id 在 fetch 未回时被下一帧重复 enter
	for id in _hi.keys():
		if not want.has(id):
			leave.append(id)
			_hi.erase(id)  # 丢引用(可能是 null 占位,也可能是真纹理)→ 显存回收
	return { "enter": enter, "leave": leave }

## 调用方异步拉到高保真图集后登记引用。只填仍在集里的——fetch 期间该角色可能已离开,
## 那样 _hi 里已无此 id,late 纹理不登记(交给局部引用自然释放)。
func hold(id: String, tex: Texture2D) -> void:
	if _hi.has(id):
		_hi[id] = tex

## 某角色是否在高保真集(含占位中)。
func is_hi(id: String) -> bool:
	return _hi.has(id)

## 已登记真纹理(非占位)的高保真角色数——单测/调试用。
func hi_count() -> int:
	return _hi.size()

## 清空(换场景时调用方主动收池,丢全部引用)。
func clear() -> void:
	_hi.clear()
