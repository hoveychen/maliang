class_name VillagerAssets
extends RefCounted
## 打包的 seed 村民资产：从 prod 默认世界抽 3 个 village 村民的 idle 动画图集（WebP），随包分发。
##
## 用途：world 的离线/intro 模式下，把 _setup_npcs 的 demo NPC 从染色 critter 占位换成真立绘
## （play_anim 动画）。做法与 loading 仙子图集同源（见 memory loading-fairy-idle-atlas）：进世界/
## 联网之前也要能动，所以图集本地打包、不走运行时 api.fetch_sprite_anim。
##
## 与转正（P3）的关系：demo NPC 用这里的 slug 作 id（demo_ 前缀 → _LOCAL_ONLY_IDS 本地专属、绝不上报）；
## sprite_asset 记录 prod 同款 seed 村民的 spriteAsset，转正时若线上就是同款，视觉可无缝对齐。
##
## 重取/更新（prod 从本机直连不通，走 muveectl 代理带鉴权；PID 见 memory maliang-server-ghcr-deploy）：
##   muveectl projects curl <PID> /worlds/default            # 找 village 村民的 appearance.spriteAsset
##   muveectl projects curl <PID> /sprite-anim/<spriteAsset> # animAsset + meta(cols/rows/frameCount/fps/cellW/cellH)
##   muveectl projects curl <PID> /assets/<animAsset> > assets/villagers/<slug>.webp
## 换图集后同步更新下方 meta 常量，并重跑 godot --headless --import 生成 .import。
## prod seed 村民形象换代时这些本地图集不会自动更新，需手动重取。

## 每个 seed 村民：本地图集路径 + 展示名 + prod spriteAsset（转正对齐用）+ 播放 meta。
## meta 字段直接喂 PaperCharacter.play_anim（需要 cols/rows/frameCount/fps/cellW/cellH）。
const SEED := [
	{
		"slug": "wuwu_rabbit",
		"name": "舞舞兔",
		"atlas": "res://assets/villagers/wuwu_rabbit.webp",
		"sprite_asset": "142b170f7f4c8e54",
		"meta": { "cols": 6, "rows": 6, "frameCount": 31, "fps": 8, "cellW": 166, "cellH": 256 },
	},
	{
		"slug": "linghu_fox",
		"name": "灵狐小围巾",
		"atlas": "res://assets/villagers/linghu_fox.webp",
		"sprite_asset": "92e458df1ff0711d",
		"meta": { "cols": 6, "rows": 6, "frameCount": 31, "fps": 8, "cellW": 220, "cellH": 256 },
	},
	{
		"slug": "huahuan_deer",
		"name": "花环小鹿",
		"atlas": "res://assets/villagers/huahuan_deer.webp",
		"sprite_asset": "22ce958273165bbf",
		"meta": { "cols": 6, "rows": 6, "frameCount": 31, "fps": 8, "cellW": 204, "cellH": 256 },
	},
]

## 世界里 seed 村民的可见高度（米）——与 _spawn_server_character 的服务端村民一致（6.0），
## 保证转正前后同款村民尺寸不跳。
const WORLD_HEIGHT := 6.0
