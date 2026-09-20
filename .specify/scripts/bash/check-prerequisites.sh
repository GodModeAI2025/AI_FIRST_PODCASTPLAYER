#!/usr/bin/env bash
# Original read-only helper; supports the common JSON/paths-only options.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
export PACKET_ROOT="$ROOT"
python3 - "$@" <<'PYCHECK'
import json,os,sys
from pathlib import Path
root=Path(os.environ['PACKET_ROOT']);feature=root/'specs/001-ai-podcast-player'
paths={'REPO_ROOT':str(root),'BRANCH':'001-ai-podcast-player','FEATURE_DIR':str(feature),'FEATURE_SPEC':str(feature/'spec.md'),'IMPL_PLAN':str(feature/'plan.md'),'TASKS':str(feature/'tasks.md')}
if '--paths-only' not in sys.argv:
 for name in ['spec.md','plan.md']+(['tasks.md'] if '--require-tasks' in sys.argv else []):
  if not (feature/name).exists():raise SystemExit('Missing: '+name)
 paths['AVAILABLE_DOCS']=[p.name for p in sorted(feature.glob('*.md'))]
print(json.dumps(paths,ensure_ascii=False) if '--json' in sys.argv else '\n'.join(f'{k}={v}' for k,v in paths.items()))
PYCHECK
