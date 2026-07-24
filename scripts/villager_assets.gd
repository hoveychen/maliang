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

## 每个 seed 村民：本地图集路径 + 展示名 + prod spriteAsset（转正对齐用）+ voice_id + 播放 meta。
## meta 字段直接喂 PaperCharacter.play_anim（cols/rows/frameCount/fps/cellW/cellH + clips 段区间）。
## 图集是 idle+talking 两段（离线 demo NPC 不出声，只会播 idle 段；转正联网后会说话动嘴）。
##
## voice_id = 这个具名种子村民的【canonical 运行期音色】，单一真相。三处必须一致，否则孩子在 intro
## 听到的招呼声进游戏后会变（违「预制音色=运行期音色」契约）：
##   ① 本字段  ② 服务端 character_defs.voiceId（prod template 世界）  ③ intro 招呼预制 WAV（assets/voice/intro/greet_*，见 lines.json 逐行 voice）
## 选声理由：兔=活泼少女 Xiaoyi、狐=阳光少年 Yunxi（不能用 Yunxia，那是点点/仙子音色，会狐≡仙子撞声）、鹿=温暖 Xiaoxiao。
const SEED := [
	{
		"slug": "wuwu_rabbit",
		"name": "舞舞兔",
		"atlas": "res://assets/villagers/wuwu_rabbit.webp",
		"sprite_asset": "142b170f7f4c8e54",
		"voice_id": "zh-CN-XiaoyiNeural",
		"meta": { "cols": 8, "rows": 8, "frameCount": 62, "fps": 8, "cellW": 244, "cellH": 256,
			"clips": { "idle": { "start": 0, "count": 31 }, "talking": { "start": 31, "count": 31 } } },
	},
	{
		"slug": "linghu_fox",
		"name": "灵狐小围巾",
		"atlas": "res://assets/villagers/linghu_fox.webp",
		"sprite_asset": "92e458df1ff0711d",
		"voice_id": "zh-CN-YunxiNeural",
		"meta": { "cols": 8, "rows": 8, "frameCount": 62, "fps": 8, "cellW": 272, "cellH": 256,
			"clips": { "idle": { "start": 0, "count": 31 }, "talking": { "start": 31, "count": 31 } } },
	},
	{
		"slug": "huahuan_deer",
		"name": "花环小鹿",
		"atlas": "res://assets/villagers/huahuan_deer.webp",
		"sprite_asset": "22ce958273165bbf",
		"voice_id": "zh-CN-XiaoxiaoNeural",
		"meta": { "cols": 8, "rows": 8, "frameCount": 62, "fps": 8, "cellW": 204, "cellH": 256,
			"clips": { "idle": { "start": 0, "count": 31 }, "talking": { "start": 31, "count": 31 } } },
	},
]

## 世界里 seed 村民的可见高度（米）——与 _spawn_server_character 的服务端村民一致（6.0），
## 保证转正前后同款村民尺寸不跳。
const WORLD_HEIGHT := 6.0
