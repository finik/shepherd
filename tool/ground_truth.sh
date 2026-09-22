#!/usr/bin/env bash
# What the host says about a pane, for comparison against what the phone shows.
set -euo pipefail
pane="$1"
herdr api snapshot 2>/dev/null | python3 -c "
import json,sys
pane = '$pane'
d = json.load(sys.stdin)['result']['snapshot']
p = next((x for x in d['panes'] if x['pane_id'] == pane), None)
if not p:
    print('no such pane'); raise SystemExit(1)
print('status  :', p.get('agent_status'))
print('title   :', repr(p.get('terminal_title_stripped')))
print('label   :', repr(p.get('label')))
path = (p.get('agent_session') or {}).get('value')
print('session :', path)
if path and path.endswith('.jsonl'):
    import os
    if not os.path.exists(path):
        print('size    : MISSING (herdr points at a file that does not exist)')
        raise SystemExit(0)
    print('size    :', os.path.getsize(path))
    tail = []
    for line in open(path):
        try: r = json.loads(line)
        except: continue
        m = r.get('message') or {}
        role = m.get('role'); c = m.get('content')
        texts = []
        if isinstance(c, str): texts.append(c)
        elif isinstance(c, list):
            for b in c:
                if isinstance(b, dict) and b.get('type') in ('text',):
                    texts.append(b.get('text',''))
                elif isinstance(b, dict) and b.get('type') in ('tool_use','toolCall'):
                    texts.append('[' + str(b.get('name')) + ']')
        if texts and role in ('user','assistant'):
            tail.append((role, ' '.join(texts).replace(chr(10),' ')[:110]))
    for role, t in tail[-6:]:
        print(f'  {role:<9} {t}')
"
