#!/usr/bin/env python3
"""内容包分发 P5：从 pack.json + 目录扫描（单一真相来源）生成 export_presets.cfg 的
内容包预设 + 主包（Android/macOS/iOS）排除列表，并输出 build/packs/registry.json
（pack 名 → {keys, export_path}）供 register-content-packs.sh 入库。

设计见 docs/content-pack-distribution-design.md。要点：
- 主题模型包按【整个资产目录】枚举资源文件（glb/gltf/png/jpg/webp），与主包排除对称——
  保证「包里有的 == 主包排除的」，杜绝依赖贴图漏排（roman 36M 大头是外挂 png）。
- 语音/音频包：voice_items（154 念名 wav）、voice_story_<册>（各册 wav + lines.json 走
  include_filter 显式带上，非资源文件）、bgm（cheery/happy 两首；carefree 菜单在放留主包）。
- 主包 export_filter="exclude" + export_files=<全部可分发资源>；include_filter 保留 mltr；
  exclude_filter 加 story lines.json（非资源，从主包剔除，未挂载时该册目录整体缺失→优雅回落 TTS）。
- 幂等：保留 3 个主预设的全部 options（签名/图标等）逐字不动，只改 filter 行；重跑覆盖所有内容包预设。

用法：python3 scripts/gen-content-pack-presets.py [--check]
  无参数=就地重写 export_presets.cfg + 写 registry.json；--check=只打印摘要不落盘。
"""
import json
import glob
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

RES_EXTS = ('.glb', '.gltf', '.png', '.jpg', '.jpeg', '.webp')
MAIN_PRESET_NAMES = {'Android', 'macOS', 'iOS'}
CFG = 'export_presets.cfg'
STORY_LINES_GLOB = 'assets/voice/story_*/lines.json'  # 非资源，从主包剔除


def dir_resources(dirs):
    out = set()
    for d in dirs:
        for root, _, files in os.walk(d):
            for f in files:
                if f.lower().endswith(RES_EXTS):
                    out.add('res://' + os.path.join(root, f))
    return sorted(out)


def build_pack_defs():
    """返回 dict: pack 名 -> {files:[res://...], include:str, keys:[...]}（有序）。"""
    packs = {}
    # 14 主题模型包（除 base）：整目录资源枚举。
    for pj in sorted(glob.glob('assets/packs/*/pack.json')):
        name = pj.split('/')[-2]
        if name == 'base':
            continue
        doc = json.load(open(pj))
        entries = doc.get('entries', {})
        dirs = sorted(set('/'.join(v['path'].replace('res://', '').split('/')[:2])
                          for v in entries.values() if 'path' in v))
        packs[name] = {'files': dir_resources(dirs), 'include': '',
                       'keys': sorted(entries.keys())}
    # 物品念名（154 wav；无 lines.json 索引，靠文件名=item_id）。
    packs['voice_items'] = {
        'files': sorted('res://' + p for p in glob.glob('assets/voice/items/*.wav')),
        'include': '', 'keys': [],
    }
    # 故事册语音（各册 wav + lines.json 显式打进包）。
    for d in sorted(glob.glob('assets/voice/story_*')):
        if not os.path.isdir(d):
            continue
        book = os.path.basename(d)
        packs['voice_' + book] = {
            'files': sorted('res://' + p for p in glob.glob(d + '/*.wav')),
            'include': 'assets/voice/%s/lines.json' % book, 'keys': [],
        }
    # 背景乐（carefree 菜单即放→留主包；余两首可分发）。
    packs['bgm'] = {
        'files': ['res://assets/audio/bgm/bgm_cheery_monday.wav',
                  'res://assets/audio/bgm/bgm_happy_boy.wav'],
        'include': '', 'keys': [],
    }
    return packs


def psa(paths):
    """PackedStringArray("a", "b", ...)"""
    return 'PackedStringArray(' + ', '.join('"%s"' % p for p in paths) + ')'


def parse_presets(text):
    """把 cfg 拆成 [(index, kind, [body_lines])]，kind ∈ {'main','options'}。保序。"""
    blocks = []
    cur = None
    for line in text.splitlines():
        m = re.match(r'^\[preset\.(\d+)(\.options)?\]\s*$', line)
        if m:
            if cur:
                blocks.append(cur)
            cur = {'index': int(m.group(1)),
                   'kind': 'options' if m.group(2) else 'main', 'lines': []}
        elif cur is not None:
            cur['lines'].append(line)
    if cur:
        blocks.append(cur)
    return blocks


def edit_main_block(lines, exclude_files):
    """主预设 main 块：export_filter→exclude、插入/替换 export_files、exclude_filter 加 lines.json 剔除。"""
    out = []
    have_files = False
    for ln in lines:
        if ln.startswith('export_filter='):
            out.append('export_filter="exclude"')
            out.append('export_files=' + psa(exclude_files))
            have_files = True
            continue
        if ln.startswith('export_files='):
            continue  # 由上面重写
        if ln.startswith('exclude_filter='):
            out.append('exclude_filter="%s"' % STORY_LINES_GLOB)
            continue
        out.append(ln)
    if not have_files:  # 理论不至于（主预设都有 export_filter）
        raise SystemExit('main preset missing export_filter line')
    return out


def render_pack_preset(index, name, spec):
    body = [
        '',
        'name="%s"' % name,
        'platform="macOS"',
        'runnable=false',
        'advanced_options=false',
        'dedicated_server=false',
        'custom_features=""',
        'export_filter="resources"',
        'export_files=' + psa(spec['files']),
        'include_filter="%s"' % spec['include'],
        'exclude_filter=""',
        'export_path="build/packs/%s.pck"' % name,
        'patches=PackedStringArray()',
        'encryption_include_filters=""',
        'encryption_exclude_filters=""',
        'seed=0',
        'encrypt_pck=false',
        'encrypt_directory=false',
        'script_export_mode=2',
        '',
    ]
    opts = [
        '',
        'export/distribution_type=0',
        'binary_format/architecture="universal"',
        'custom_template/debug=""',
        'custom_template/release=""',
        '',
    ]
    txt = '[preset.%d]\n' % index + '\n'.join(body) + '\n'
    txt += '[preset.%d.options]\n' % index + '\n'.join(opts) + '\n'
    return txt


def main():
    check = '--check' in sys.argv
    packs = build_pack_defs()
    exclude_files = sorted({f for p in packs.values() for f in p['files']})

    text = open(CFG).read()
    blocks = parse_presets(text)
    # 按 index 归组，抓出 3 个主预设的 main + options 块（逐字保留 options）。
    by_index = {}
    for b in blocks:
        by_index.setdefault(b['index'], {})[b['kind']] = b['lines']
    main_presets = []  # [(name, main_lines(edited), options_lines)]
    for idx in sorted(by_index):
        blk = by_index[idx]
        if 'main' not in blk:
            continue
        name = None
        for ln in blk['main']:
            m = re.match(r'^name="(.*)"$', ln)
            if m:
                name = m.group(1)
                break
        if name in MAIN_PRESET_NAMES:
            main_presets.append((name,
                                 edit_main_block(blk['main'], exclude_files),
                                 blk.get('options', [])))
    if len(main_presets) != 3:
        raise SystemExit('expected 3 main presets, found %d' % len(main_presets))

    # 摘要
    total = 0
    print('=== content packs ===')
    for name in sorted(packs):
        n = len(packs[name]['files'])
        sz = sum(os.path.getsize(f.replace('res://', '')) for f in packs[name]['files']
                 if os.path.exists(f.replace('res://', '')))
        total += sz
        print('  %-22s %3d files  %6.1f MB  keys=%d' % (name, n, sz / 1e6, len(packs[name]['keys'])))
    print('  main-package exclude union: %d files, %.1f MB' % (len(exclude_files), total / 1e6))

    if check:
        return

    # 生成新 cfg
    out = []
    for i, (name, main_lines, opt_lines) in enumerate(main_presets):
        out.append('[preset.%d]\n' % i + '\n'.join(main_lines) + '\n')
        out.append('[preset.%d.options]\n' % i + '\n'.join(opt_lines) + '\n')
    idx = len(main_presets)
    registry = {}
    for name in sorted(packs):
        out.append(render_pack_preset(idx, name, packs[name]))
        registry[name] = {'keys': packs[name]['keys'],
                          'export_path': 'build/packs/%s.pck' % name}
        idx += 1
    open(CFG, 'w').write(''.join(out))
    os.makedirs('build/packs', exist_ok=True)
    json.dump(registry, open('build/packs/registry.json', 'w'), indent=2, ensure_ascii=False)
    print('\nwrote %s (%d presets: 3 main + %d packs)' % (CFG, idx, len(packs)))
    print('wrote build/packs/registry.json')


if __name__ == '__main__':
    main()
