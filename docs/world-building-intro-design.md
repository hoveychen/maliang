# 「建造小世界」合并前置阶段设计

> 新手引导(纯客户端虚拟场景) + 画质 benchmark 定档 + 网络后台预载,三合一的故事化前置阶段。
> 对应 TASKS.md 计划 `world-building-intro`(本文档是其设计依据)。

## 1. 背景:三件事撞在同一个时间窗

孩子从点开 app 到真正玩上,中间要发生三件互不相干的慢事:

1. **画质定档**(仅新 GPU):众包未命中时本机跑贪心 benchmark,上限 ~108s(`benchmark.gd MAX_MEASURES`)。现状是 loading 里 `_resolve_graphics()` 的网络查询卡在进世界的关键路径上,曾造成 loading 卡死;benchmark 跑完还要 `change_scene` 整个重进一遍世界。
2. **网络引导**(每次冷启动):`world._bootstrap()` 拉 world_state → 地形 → 并发预取全部村民素材 → 逐个降生。首次冷启动是大头(此后有 `user://asset_cache` 内容寻址缓存,二次启动近乎瞬时)。现状靠 loading 过场遮住,超时 8s 硬放行后村民"弹入"。
3. **新手引导**(仅首次):现有绘本 onboarding 只教了自我介绍和形象生成,孩子进世界后没人教"点哪里走路、怎么跟村民说话"。

这三件事的共同点:**都需要一段孩子不无聊的时间**。与其串行等三次,不如合并成一个前置演出段——前台仙子讲故事建世界,后台把慢事全干了。

### 现状盘点(已实际读码验证)

| 能力 | 状态 | 出处 |
|---|---|---|
| 离线完整地形 | ✅ 打包 village+forest 矩阵/POI/传送门/内置物品 | `assets/terrain/`,`world.gd:380`"离线也有完整世界" |
| 离线占位村民 | ⚠️ 3 个 `critter.png` 染色小生物(小蓝/小绿/小黄),非真立绘 | `world.gd:719 _setup_npcs`,在线 bootstrap 清除,`demo_` 前缀永不上报(`world.gd:2100`) |
| 离线仙子 | ✅ 图集+预制语音全本地,`fairy_idle.webp` 31 帧 | `_setup_fairy_offline`,`assets/voice/fairy/` |
| 资产磁盘缓存 | ✅ 内容寻址,图/音/地形均落 `user://asset_cache` | `api.gd _cache_read/_cache_write` |
| 村民并发预取 | ✅ `_prefetch_characters` anim 优先并发拉 | `world.gd:3609` |
| benchmark 复用 world 渲染路径 | ✅ `Benchmark.pending` → world 短路后端/麦/引导 | `benchmark.gd` 头注释 |
| 预制语音管线 | ✅ `server/tools/gen_voice_lines.mjs` + `lines.json` → WAV 打包 | onboarding/fairy 两套已在用 |
| 打包服务端生成图集的先例 | ✅ loading 仙子图集从 prod animAsset 拉下打包 WebP | `loading.gd` 仙子常量注释 |

**结论:纯客户端前置阶段的底子已经齐了,唯一的资产缺口是"好看的预制村民"。**

## 2. 目标与非目标

**目标**

- 首次启动:孩子在一个纯客户端可玩的虚拟场景里被引导(走路/靠近村民/开口说话),同时后台完成 benchmark(若需要)与全部网络预取;演出结束时世界"原地转正",无二次加载、无村民弹入。
- 二次启动(有档案有画质档):路径完全不变(menu → loading → world),本设计零侵入。
- 修掉 loading 画质决议阻塞 gate(止血项,独立可先行)。

**非目标**

- 不做真 LLM 对话的离线化——引导期对话全部脚本化预制。
- 不改绘本 onboarding 的内容(自我介绍/形象生成保持现状,仍在前置阶段之前)。
- 不动 benchmark 的贪心算法与达标线,只动它的"编排与收尾"。

## 3. 总体方案:world 的 intro 模式(不新增场景)

benchmark 已经证明了正确姿势:**要测/要演的就是真实世界那条渲染路径,另起炉灶必然漂移**。所以前置阶段不是新场景,而是 `main.tscn`(world)的一个开局模式,类比 `Benchmark.pending`:

- intro 模式下 world 照常 `_ready`:打包地形、预制村民(替换 critter 占位)、本地仙子——这本身就是"虚拟场景"。
- 演出编排器(新节点,挂在 world 上,类比 `Benchmark.make(world)`)驱动多段旁白+建造动画+教学步骤+benchmark 段。
- 后台并行:画质众包查询/benchmark、`_bootstrap` 的 **fetch 半段**(见 D3)。
- 演出结束 → **原地转正**:一次性把 fetch 好的服务端状态演出化地应用进场景,不换场景、不重载。

### 分流矩阵

| 档案 | 画质档 | 路径 |
|---|---|---|
| 无 | 无 | menu → 绘本 onboarding → world(intro:教学+建造+benchmark 段) → 原地转正 |
| 无 | 有(众包命中) | menu → 绘本 → world(intro:教学+建造,无 benchmark 段) → 原地转正 |
| 有 | 无(重新检测/新 GPU) | menu → world(intro:仅建造+benchmark 段,无教学) → 原地转正 |
| 有 | 有 | menu → loading → world(**现状,完全不变**) |

绘本 onboarding 仍在最前:它要收集档案、预生成玩家形象(`/player-sprite`,intro 页起预取),这些必须在进世界前定音;它是 2D Control 场景,与画质档无关,不必等 benchmark。另外教学期孩子在世界里用的就是自己刚生成的形象,代入感更强。
(沿革:2026-07-11 早先曾拍板"建造阶段在 menu 后、onboarding 之前"——那是 intro 还只是 benchmark 演出时的排序;合并教学后改为绘本在前,经老板决策卡确认,取代旧排序。)

## 4. 关键设计决策

### D1 载体:world intro 模式,而非独立场景

理由同 benchmark 头注释:测/演的就是真实渲染路径。额外收益:**转正无需换场景**,省掉 benchmark 现在"测完 `change_scene_to_file(loading.tscn)` 重进一遍"的整轮重载(`benchmark.gd:248`),也省掉第二次 loading 过场。

### D2 预制村民:从 prod 抽 seed 村民图集打包

- 参照 loading 仙子图集先例:从 prod 资产库拉 2~3 个 seed 村民(村庄场景的)的 **anim 图集(WebP)+ trim 立绘**,落 `assets/villagers/`,随包分发。
- intro 模式里 `_setup_npcs` 的三个 critter 占位换成这些真立绘(id 仍用 `demo_` 前缀语义——本地专属、绝不上报,复用 `_LOCAL_ONLY_IDS` 机制)。
- 转正时:在线则清 demo、spawn 服务端村民(素材已预取,瞬时)。**若服务端就是同款 seed 村民,视觉上无缝**(同图集,仅 id 换);若线上形象已重生成过,会有一次形象切换,接受(可包装成"眨眼变装")。
- 包体增量:参照仙子图集,单村民图集预计几百 KB 级,3 个 <1.5MB;**P2 落地时实测并回报**。
- 打包资产需注意 worktree 导出陷阱(gitignored 资产不进干净 worktree,见既有教训):图集 WAV 一律 git tracked。

### D3 bootstrap 拆成 fetch / apply 两阶段

现在 `_bootstrap()` 是"边拉边应用":拿到 world 就清 demo、逐个降生、搬玩家。intro 模式需要拆开:

- **fetch 半段**(intro 一开始就后台跑):`get_world` → `ItemCatalog.set_defs` 数据就位 → 地形 diff 预取 → `_prefetch_characters` 全量并发预取 → 玩家形象预取。只落缓存和内存,**不动场景任何节点**。
- **apply 半段**(转正点执行,演出化):清 demo 村民 → 服务端村民按建造演出逐个"降生"(素材全在缓存,零等待) → 地形若与打包一致则 `changed=false` 零重铺 → 玩家/仙子搬到最终位 → backend WS 接通后的常规运行态。
- **intro 结束但 fetch 未完**(弱网):不阻塞转正,世界先以离线形态交给孩子,沿用现有"网络角色后补弹入"路径——和今天的超时兜底行为一致,只是概率大幅降低(intro 演出至少 1~2 分钟,远超现在 8s 的遮罩窗口)。
- **离线**:intro 照常走完(纯客户端),转正点发现离线 → 保持虚拟世界可玩,现有离线模式语义不变。

### D4 教学内容边界:手势教学,不是对话教学

纯客户端 = 没有 LLM。引导期一切"对话"都是脚本:

- **走路**:仙子旁白"点一下那边的大树"→ 检测到玩家移动 → 预制夸奖。
- **靠近村民**:旁白引导走近预制村民 → 村民 emote 回应(挥手/爱心,复用 player-interaction 的 emote 表现)。**预制村民不开口说话**——预制音色必须等于运行期音色的契约(见资产盘点文档),为 2~3 个村民各预制一套台词不值当;仙子代言一切。
- **开口说话**:教的是"话筒亮了就可以说"这个手势——本地 VAD/ASR 检测到孩子开口即算完成,仙子预制回应,**不理解内容**。麦 gating 复用 onboarding-vad 的 `asr_ready` 门禁:Android 端侧 ASR 未就绪不开麦、绝不上传 PCM。
- 有档案的用户(仅 benchmark 路径)跳过全部教学段,只看建造+注魔演出。

### D5 benchmark 采样窗与演出交替编排

贪心测量的前提是**可复现帧**(benchmark 头注释:玩家不动→相机不动→每帧一样)。演出动画会污染 p95,所以:

- 采样窗内:画面静止,仙子"凝神注魔"造型(定格姿势),旁白可以继续播(音频不占 GPU)。
- 采样窗之间(换档/试错的间隙):播建造动画——物件浮现、村民降生、**画质切换本身包装成"世界越来越清晰"**。
- 编排点用 Benchmark 现有的 `progress` 信号;测完 `finished` 就地 `GraphicsSettings` 应用,不再 reload(D1)。
- benchmark 的 EXTRA_CHARS 12 个压测角色在 intro 里以"精灵光点/村民雏形"的演出身份出现,测完退场。

### D6 止血项独立先行(原计划 P1,**已完成**)

loading 的 `_resolve_graphics()` 网络查询挪出阻塞路径:定过档/桌面直接进;没定过档 → 保守默认档必进世界,众包查询与 benchmark 触发交给 intro 阶段接管。这一步不依赖本设计其余部分,已先行落地(TASKS.md P1 已勾)。

## 5. 演出脚本骨架(多段旁白)

预制旁白走 `gen_voice_lines.mjs` 管线(仙子音色,同 `assets/voice/fairy/` 一套),`assets/voice/intro/lines.json`:

1. **开场**:一片朦胧(保守档+雾),仙子登场:"欢迎来到精灵世界!我们一起把它变出来吧。"
2. **建造段**:地形/树木/房屋分批浮现(实际是 chunk 铺设+SDF 物件本来就要做的事,演出只是控制节奏与镜头);后台 fetch 全速跑。
3. **注魔段**(仅无画质档):仙子注魔定格,采样窗轮转,间隙里世界逐步"清晰成形"(画质档爬升)。
4. **伙伴段**:预制村民降生(蛋壳/光团,复用降生蛋占位符语汇,注意别撞传送门造型)。
5. **教学段**(仅无档案):走路 → 靠近村民 → 开口说话,见 D4。
6. **转正**:仙子"世界准备好啦!"→ apply 半段演出化执行 → 控制权完全交给孩子。

每段有超时兜底(旁白播完+最长等待即推进),整段演出可被家长长按跳过(跳过时:benchmark 未完则记 `Benchmark.pending` 留待后台/下次,fetch 继续后台跑,直接转正)。

## 6. 实施拆解

对应 TASKS.md `world-building-intro` 计划(合并后):

- **P1 止血**:loading 去阻塞 gate(D6);headless 回归。**已完成**。
- **P2 预制村民资产**:prod 抽图集打包+intro 换真立绘+包体实测(D2)。
- **P3 intro 模式骨架**:分流条件+bootstrap 拆 fetch/apply+转正+离线/跳过兜底(D3);headless 冒烟。
- **P4 旁白+教学**:lines.json+gen 管线+教学脚本+麦 gating(D4)。
- **P5 benchmark 段**:采样窗编排+就地应用不 reload+建造动画(D5)。
- **P6 验收**:全套回测+真机清单+merge --no-ff(老板验收门)。

## 7. 风险与开放问题

- **真机 benchmark 至今一次没实证**(P1 摘除自动触发后更是零路径):哪个旋钮真机真省 ms、贪心总耗时、12 角色负载够不够,全未知。P5 接回后必须真机跑通一次,这是 P6 真机清单的头号项。
- **prod seed 村民与打包村民漂移**:线上重新生成过形象则转正有一次视觉切换。缓解:打包资产版本随发版更新;或转正做变装演出。
- **benchmark 时长感**:最弱机器 108s 上限,旁白+建造动画要填得住;实测节奏后可能要加第二轮旁白素材。
- **弱网下教学段的"说话"步骤**:依赖端侧 ASR;端侧未就绪(旧 Android 首次模型加载)则教学段跳过说话步,只教走路/靠近——不能为教学开服务端 PCM 上传的口子。
- **包体预算**:村民图集+intro 旁白 WAV 预计 <3MB 增量,P2/P4 落地时实测回报,超预算再议(如旁白降采样)。
- **开放问题(留老板)**:教学段要不要教"捡东西/物品"?现有 scene-items 拾摆已上线,加一步演出成本不高,但引导变长;缺省先不教。
