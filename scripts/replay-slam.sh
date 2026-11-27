#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
reopen=(open build/Hammertime.app)
launch=(--no-activate)
for option in "$@"; do
  case "$option" in
    --banner) reopen=(true) ;;
    --smash) launch+=(--smash-every-merge) ;;
    *)
      printf 'Usage: %s [--banner] [--smash]\n' "$0" >&2
      exit 1
      ;;
  esac
done
if [[ ! -d build/Hammertime.app ]]; then
  printf 'Build Hammertime first with ./scripts/build-app.sh.\n' >&2
  exit 1
fi
if pgrep -x Hammertime >/dev/null; then
  osascript -e 'quit app "Hammertime"'
  while pgrep -x Hammertime >/dev/null; do sleep 0.2; done
fi
python3 - <<'PY'
import json, os, sys
path = os.path.expanduser('~/Library/Application Support/Hammertime/state.json')
if not os.path.exists(path):
    sys.exit('Connect a GitHub account in Hammertime first.')
state = json.load(open(path))
pulls = [pull for connection in state['connections'] for pull in connection['snapshot']['pullRequests']]
if not pulls:
    sys.exit('No merged PRs to replay.')
newest = max(pulls, key=lambda pull: pull['mergedAt'])
for connection in state['connections']:
    snapshot = connection['snapshot']
    snapshot['pullRequests'] = [pull for pull in snapshot['pullRequests'] if pull['id'] != newest['id']]
    snapshot['fetchedAt'] = min(snapshot['fetchedAt'], newest['mergedAt'])
print('Replaying:', newest['title'])
with open(path + '.replay', 'w') as file:
    json.dump(state, file)
os.chmod(path + '.replay', 0o600)
os.replace(path + '.replay', path)
PY
open -g -j build/Hammertime.app --args "${launch[@]}"
"${reopen[@]}"
