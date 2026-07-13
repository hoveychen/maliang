/**
 * 按名字在清单里找东西：先精确，再互相包含。
 *
 * ASR 转写多字/少字是常态（「小蓝呀」↔「小蓝」、「去风车那儿」↔「风车」），精确匹配一条路走不通。
 * 原先只在 voice.ts 里给花名册用（findByName），引路（guide.ts）要按同样的宽容度匹配角色和地点，
 * 故提出来共用——两边的匹配尺度必须一致，否则 LLM 报的名字在 A 处认得、B 处不认得。
 */
export function matchByName<T extends { name: string }>(list: T[], name: string): T | undefined {
  const n = name.trim();
  if (!n) return undefined;
  return list.find((c) => c.name === n) ?? list.find((c) => c.name.includes(n) || n.includes(c.name));
}
