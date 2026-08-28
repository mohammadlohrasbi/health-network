#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check-runbook.py — اعتبارسنجی دستورهای RUNBOOK در برابر درخت واقعی.

چرا فایل جدا و نه یک‌خطی داخل patch-domain.sh؟ چون منطقش رجکس دارد
و رجکس داخل رشتهٔ bash داخل رشتهٔ python سه لایه escape می‌خواهد —
یک بار نوشتمش و بی‌صدا هیچ‌چیز نگرفت. هر منطقی که escape سه‌لایه
لازم دارد، فایل خودش را می‌خواهد.

سه چیز را می‌سنجد:

۱. هر بلوک ```bash باید از پوشهٔ مشخصی اجرا شود. `cd` را داخل بلوک
   دنبال می‌کند و هر فایل نام‌برده را از پوشهٔ همان لحظه می‌سنجد.
   باگی که این را لازم کرد: بلوک A9 مسیرها را از ریشه می‌نوشت ولی
   با `cd scripts` ادامه می‌داد → `scripts/scripts/gen-...js`.

۲. هر نام کانال باید در channel_contract_map.sh باشد.

۳. هر نام قرارداد پس از `-n` باید در contract-fn-map.js باشد.
"""

import json
import os
import re
import subprocess
import sys

PROJECT_PATH = '/root/health-network'


def blocks(text):
    return re.findall(r'```bash\n(.*?)```', text, re.S)


def code_lines(block):
    out = []
    for raw in block.split('\n'):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        out.append(line)
    return out


def check_paths(text, root):
    """cd را دنبال کن و هر فایل نام‌برده را از پوشهٔ همان لحظه بسنج."""
    problems = []
    cd_re = re.compile(r'cd (' + re.escape(PROJECT_PATH) + r'[A-Za-z0-9_/.-]*)')
    file_re = re.compile(
        r'(?:bash |node |source )?((?:\.\.?/)?[A-Za-z0-9_/.-]+\.(?:sh|js))(?:\s|$)')

    for i, block in enumerate(blocks(text)):
        cwd = None
        for line in code_lines(block):
            m = cd_re.match(line)
            if m:
                cwd = os.path.join(root, m.group(1)[len(PROJECT_PATH):].lstrip('/'))
                # `cd X && cmd` — بخش پس از && مسیر نیست
                cwd = cwd.split(' &&')[0]
                if not os.path.isdir(cwd):
                    problems.append(f'بلوک {i}: پوشه وجود ندارد — {line}')
                    cwd = None
                continue
            if cwd is None:
                continue
            m2 = file_re.match(line)
            if not m2:
                continue
            target = os.path.normpath(os.path.join(cwd, m2.group(1)))
            if not os.path.exists(target):
                rel = os.path.relpath(cwd, root)
                problems.append(
                    f'بلوک {i}: «{m2.group(1)}» از {rel}/ پیدا نشد')
    return problems


def check_names(text, root):
    """نام کانال و قرارداد باید واقعی باشند."""
    problems = []
    fn_map = os.path.join(root, 'server', 'contract-fn-map.js')
    if not os.path.exists(fn_map):
        return ['contract-fn-map.js نیست — اول مولد را اجرا کنید']

    js = ('const m=require(%s);'
          'console.log(JSON.stringify({ch:Object.keys(m.CHANNEL_CHAINCODE_MAP),'
          'cc:Object.keys(m.CONTRACT_FN)}))') % json.dumps(fn_map)
    try:
        raw = subprocess.run(['node', '-e', js], capture_output=True,
                             text=True, check=True, timeout=30).stdout
        data = json.loads(raw)
    except Exception as exc:                       # noqa: BLE001
        return [f'contract-fn-map.js خوانده نشد: {exc}']

    channels, contracts = set(data['ch']), set(data['cc'])

    # نام تابع مثل deploy_one_channel و resolve_channel کانال نیست
    named = {m for m in re.findall(r'\b(\w+channel)\b', text)
             if not re.match(r'^(deploy|resolve|control|one)_', m)}
    for ch in sorted(named - channels):
        problems.append(f'کانال ناموجود: {ch}')

    for cc in sorted(set(re.findall(r'-n (\w+)', text)) - contracts):
        problems.append(f'قرارداد ناموجود: {cc}')

    return problems


def check_legacy_channels(root):
    """هیچ اسکریپتی نباید نام کانال 6G را در پیام یا دستور راهنما
    داشته باشد. سه بار همین اتفاق افتاد: `fix-tape-policy.sh` دستور
    اجرایی روی `datachannel` می‌داد، `network.sh` آن را به عنوان
    «اولین کانال» پیشنهاد می‌کرد، و `patch-tls-detect.sh` فایلی
    نام می‌برد که ساخته نمی‌شود.

    مستثنا فقط جایی است که **عمداً** دربارهٔ آن نام‌ها حرف می‌زند:
    جدول ترجمهٔ LEGACY_CHANNEL، اسکریپت پچ، و کامنت bootstrap.
    """
    legacy = ('datachannel', 'iotchannel', 'networkchannel',
              'resourcechannel', 'performancechannel', 'securitychannel')
    skip = ('patch-domain.sh', 'channel_contract_map.sh', 'bootstrap-secure.sh')
    problems = []
    scripts = os.path.join(root, 'scripts')
    if not os.path.isdir(scripts):
        return problems
    for name in sorted(os.listdir(scripts)):
        if not name.endswith('.sh') or name in skip:
            continue
        with open(os.path.join(scripts, name), encoding='utf-8',
                  errors='replace') as handle:
            body = handle.read()
        hits = sorted({c for c in legacy if c in body})
        if hits:
            problems.append(f'{name}: نام کانال 6G — {", ".join(hits)}')
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    path = os.path.join(root, 'RUNBOOK.md')
    if not os.path.exists(path):
        print('RUNBOOK.md نیست', file=sys.stderr)
        return 1

    with open(path, encoding='utf-8') as handle:
        text = handle.read()

    problems = (check_paths(text, root)
                + check_names(text, root)
                + check_legacy_channels(root))
    if problems:
        for line in problems:
            print('  ✗ ' + line, file=sys.stderr)
        return 1

    print(f'  ✓ RUNBOOK: {len(blocks(text))} بلوک bash، همه معتبر؛ '
          'اسکریپت‌ها بدون نام کانال 6G')
    return 0


if __name__ == '__main__':
    sys.exit(main())
