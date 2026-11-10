#!/usr/bin/env bash
# shared helpers
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.foundry/bin:$PATH"
set -a; source "$ROOT/${CONFIG:-config.env}"; source "$ROOT/.secrets"; set +a
DEPLOY_FILE="${DEPLOY_FILE:-$ROOT/deployments/testnet.json}"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
jget() { python3 -c "import json,sys;print(json.load(open('$DEPLOY_FILE')).get('$1',''))" 2>/dev/null || true; }
jset() { python3 - "$1" "$2" <<'P'
import json,sys,os
f=os.environ['DEPLOY_FILE']; d=json.load(open(f)) if os.path.exists(f) else {}
d[sys.argv[1]]=sys.argv[2]; json.dump(d,open(f,'w'),indent=2)
P
}
export DEPLOY_FILE
create() { # rpc key value contract args...
  local rpc=$1 key=$2 value=$3 contract=$4; shift 4
  forge create --broadcast --json --rpc-url "$rpc" --private-key "$key" --value "$value" "$contract" \
    ${1:+--constructor-args "$@"}
}
send() { # rpc key to sig args...  -> prints tx hash
  local rpc=$1 key=$2; shift 2
  cast send --json --rpc-url "$rpc" --private-key "$key" "$@" | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['status'] in ('0x1',1,'1'),r;print(r['transactionHash'])"
}
