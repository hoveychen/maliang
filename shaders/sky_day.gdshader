shader_type sky;
// 白天动态天空：垂直渐变 + 卡通云漂移 + 太阳光晕。
// 注意：本项目相机俯视 47°(god)/30°(lock) + world-bending 下弯，可见天空带在
// EYEDIR.y ≈ [-0.55, -0.05]——视觉地平线因世界下弯远低于真水平线。渐变/云/太阳的
// 默认参数都按这个负 y 带标定，不要照抄常规 sky shader 的 y>0 假设（那样整个可见
// 天空只剩地平线单色、云永不出现）。
// 深度雾把远处地面渐隐到 horizon_color（须与 world.gd 的 fog_light_color 一致），
// 天空底部同色 → 地面与天空无缝衔接，保留无限地平线观感。

uniform vec3 horizon_color : source_color = vec3(0.62, 0.82, 0.97); // 必须与雾色一致
uniform vec3 zenith_color : source_color = vec3(0.33, 0.58, 0.93);
uniform float horizon_y = -0.55;   // 视觉地平线的 EYEDIR.y（世界下弯 → 远低于 0）
uniform float zenith_y = 0.35;     // 渐变到天顶色的 EYEDIR.y
uniform sampler2D cloud_tex : hint_default_black, filter_linear_mipmap, repeat_enable; // 无缝 FBM 噪声
uniform float cloud_scale = 0.9;   // 云 uv 缩放（穹顶投影）
uniform vec2 wind = vec2(0.006, 0.0015); // 云漂移速度（uv/秒），非零 = 动态（world 按它积分 cloud_offset）
// 云漂移相位：由 world 每 ~0.25s 步进（wind × 累计时间）。不要在本 shader 里用 TIME——
// sky shader 一沾 TIME，radiance 环境贴图就逐帧重烘（多出整条渲染 pass），
// 老 Mali 驱动上 pass 切换/同步开销极大；CPU 节流步进视觉无感且 radiance 只按需重烘。
uniform vec2 cloud_offset = vec2(0.0);
uniform float cloud_coverage = 0.52; // 噪声高于此值成云（调低云更多）
uniform float cloud_softness = 0.18; // 云边过渡宽度（卡通软边）
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_shade : source_color = vec3(0.78, 0.86, 0.98); // 云体暗部（淡蓝灰）
uniform float cloud_opacity = 0.9;
// 装饰太阳：方向与实际 DirectionalLight 解耦——真实光源位于相机背后（画不进画面），
// 且把光转到可见半球会让面向相机的纸片角色背光变黑。卡通风格下阴影方向不一致可接受。
uniform vec3 sun_dir = vec3(-0.55, -0.18, -0.82); // 默认落在 lock 视角天空带上部偏左（视觉 QA 调参）
uniform vec3 sun_color : source_color = vec3(1.0, 0.97, 0.86);
uniform float sun_disc_size = 0.008;  // 日轮尺寸（1-cosθ 域）
uniform float sun_halo_power = 24.0;  // 光晕收敛（越大越集中）
uniform float sun_halo_strength = 0.45;

void sky() {
	float y = EYEDIR.y;
	// 垂直渐变（可见带大部分位于 y<0，见文件头注释）
	float t = smoothstep(horizon_y, zenith_y, y);
	vec3 col = mix(horizon_color, zenith_color, t);

	// 太阳：宽光晕 + 小日轮
	vec3 sdir = normalize(sun_dir);
	float sun_amt = clamp(dot(EYEDIR, sdir), 0.0, 1.0);
	col += sun_color * pow(sun_amt, sun_halo_power) * sun_halo_strength;
	col = mix(col, sun_color, smoothstep(1.0 - sun_disc_size, 1.0 - sun_disc_size * 0.45, sun_amt));

	// 卡通云：穹顶投影（分母 y+1.35 无奇点，负 y 带照样有云），无缝噪声 + 风漂移
	vec2 uv = EYEDIR.xz * cloud_scale / (y + 1.35) + cloud_offset;
	float n = texture(cloud_tex, uv).r;
	float cl = smoothstep(cloud_coverage, cloud_coverage + cloud_softness, n);
	cl *= smoothstep(horizon_y, horizon_y + 0.22, y); // 近地平线的云融进雾带
	vec3 ccol = mix(cloud_shade, cloud_color, smoothstep(cloud_coverage, cloud_coverage + 0.35, n));
	col = mix(col, ccol, cl * cloud_opacity);

	COLOR = col;
}
