#!/usr/bin/env bash
# LOCAL SIMULATION of the full loop on a single anvil node (no testnet funds needed).
# A mock system contract is etched at 0x8888...8888; this script plays Reactive Network's role
# (delivering the matching log to react() and posting the requested callback). Live proof = scripts/demo.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
export PATH="$HOME/.foundry/bin:$PATH"
say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; sleep ${PAUSE:-0}; }
RPC=http://127.0.0.1:8545
SYS=0x8888888888888888888888888888888888888888
CRON100=0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70
anvil --chain-id 31337 --silent & APID=$!; trap "kill $APID" EXIT; sleep 1.5
# anvil default accounts
USER_KEY=$(cast wallet private-key "test test test test test test test test test test test junk" 0); USER=$(cast wallet address $USER_KEY)
EMP_KEY=$(cast wallet new --json | python3 -c "import json,sys;d=json.load(sys.stdin)['data'];d=d[0] if isinstance(d,list) else d;print(d['private_key'])")
EMP=$(cast wallet address $EMP_KEY)
SAV=0x000000000000000000000000000000000005AFE5; RENT=0x0000000000000000000000000000000000001A4D
q() { cast send --json --rpc-url $RPC --private-key ${K:-$USER_KEY} "$@" | python3 -c "import json,sys;r=json.load(sys.stdin);assert r['status'] in ('0x1',1),r;print(r['transactionHash'])"; }
mk() { forge create --broadcast --json --rpc-url $RPC --private-key $USER_KEY "$@" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])"; }
bal() { cast call $TOKEN "balanceOf(address)(uint256)" $1 --rpc-url $RPC | awk '{printf "%.2f", $1/1e6}'; }

say "Setup (local anvil, chain 31337): etch mock system contract at $SYS"
cast rpc anvil_setCode $SYS $(forge inspect test/mocks/MockSystem.sol:MockSystem deployedBytecode) --rpc-url $RPC >/dev/null
TOKEN=$(mk src/TestUSD.sol:TestUSD)
RC=$(mk --value 1ether src/PaydayReactive.sol:PaydayReactive --constructor-args 31337 31337 $TOKEN $USER 100000000 $EMP $CRON100 2592000)
EX=$(mk src/PaydayExecutor.sol:PaydayExecutor --constructor-args $SYS $RC $TOKEN $SAV 2000 1000000000)
q $RC "setExecutor(address)" $EX >/dev/null
q $TOKEN "approve(address,uint256)" $EX $(cast max-uint) >/dev/null
q $EX "setRecurring(address,uint256,uint256)" $RENT 900000000 2160000 >/dev/null
q $TOKEN "mint(address,uint256)" $EMP 10000000000 >/dev/null
cast rpc anvil_setBalance $EMP 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null
echo "TestUSD        $TOKEN"; echo "PaydayReactive $RC  (subscriptions: $(cast call $SYS 'activeSubs(address)(uint256)' $RC --rpc-url $RPC))"; echo "PaydayExecutor $EX"
echo "Rules: save 20% of paychecks >= 100 tUSD from $EMP, max 1,000/day; rent 900 tUSD every 30 days"

network() { # $1 = origin tx hash: deliver matching Transfer logs to react(), then post requested callbacks
  local before=$(cast call $SYS 'reqCount()(uint256)' --rpc-url $RPC)
  python3 - "$1" "$RC" "$TOKEN" "$USER" <<'P' | while read -r TUP; do q --gas-limit 3000000 $SYS "trigger(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))" $RC "$TUP" >/dev/null; echo "   [network] react() delivered on Reactive side"; done
import json,subprocess,sys
tx,rc,tok,user=sys.argv[1:]
r=json.loads(subprocess.check_output(['cast','receipt','--json',tx,'--rpc-url','http://127.0.0.1:8545']))
T='0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
for l in r['logs']:
  if l['address'].lower()==tok.lower() and l['topics'][0]==T and int(l['topics'][2],16)==int(user,16):
    print('(31337,%s,%d,%d,%d,0,%s,%d,3,%d,%d,%d)'%(l['address'],int(T,16),int(l['topics'][1],16),int(l['topics'][2],16),l['data'],int(l['blockNumber'],16),int(l['blockHash'],16),int(tx,16),int(l['logIndex'],16)))
P
  local after=$(cast call $SYS 'reqCount()(uint256)' --rpc-url $RPC)
  for ((i=before;i<after;i++)); do CB=$(q --gas-limit 3000000 $SYS "deliver(uint256)" $i); echo "   [network] callback posted to PaydayExecutor: $CB"; done
  if [ "$before" = "$after" ]; then echo "   [network] react() filtered it out -> no callback requested (nothing moved)"; fi
}

say "Before: wallet=$(bal $USER) savings=$(bal $SAV) landlord=$(bal $RENT)"
say "1) Payday: employer sends 3,000 tUSD to the wallet"
TX=$(K=$EMP_KEY q $TOKEN "transfer(address,uint256)" $USER 3000000000); echo "   origin tx $TX"; network $TX
say "   wallet=$(bal $USER)  savings=$(bal $SAV)   <- 20% saved automatically"
say "2) A stranger airdrops 500 tUSD (untrusted payer) -> ignored"
q $TOKEN "mint(address,uint256)" 0x000000000000000000000000000000000000dEaD 500000000 >/dev/null
cast rpc anvil_impersonateAccount 0x000000000000000000000000000000000000dEaD --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance 0x000000000000000000000000000000000000dEaD 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null
TX=$(cast send --json --unlocked --from 0x000000000000000000000000000000000000dEaD --rpc-url $RPC $TOKEN "transfer(address,uint256)" $USER 500000000 | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])"); echo "   origin tx $TX"; network $TX
say "   savings=$(bal $SAV)  (unchanged)  ignoredEvents=$(cast call $RC 'ignoredEvents()(uint256)' --rpc-url $RPC)"
say "3) Second paycheck of 6,000 tUSD the same day -> daily cap (1,000) limits the sweep"
TX=$(K=$EMP_KEY q $TOKEN "transfer(address,uint256)" $USER 6000000000); echo "   origin tx $TX"; network $TX
say "   savings=$(bal $SAV)  (600 + 400 = capped at 1,000/day)"
say "4) 30 days pass; a CRON tick arrives on Reactive -> rent is due"
cast rpc evm_increaseTime 2592001 --rpc-url $RPC >/dev/null; cast rpc evm_mine --rpc-url $RPC >/dev/null
before=$(cast call $SYS 'reqCount()(uint256)' --rpc-url $RPC)
q --gas-limit 3000000 $SYS "trigger(address,(uint256,address,uint256,uint256,uint256,uint256,bytes,uint256,uint256,uint256,uint256,uint256))" $RC "(31337,0x0000000000000000000000000000000000fffFfF,$(cast to-dec $CRON100),0,0,0,0x,0,1,0,0,0)" >/dev/null
echo "   [network] Cron100 delivered to react()"
CB=$(q --gas-limit 3000000 $SYS "deliver(uint256)" $before); echo "   [network] callback posted: $CB"
say "   landlord=$(bal $RENT)  totalPaid=$(cast call $EX 'totalPaid()(uint256)' --rpc-url $RPC | awk '{print $1/1e6}')"
say "Final: wallet=$(bal $USER) savings=$(bal $SAV) landlord=$(bal $RENT)  | incomeEvents=$(cast call $RC 'incomeEvents()(uint256)' --rpc-url $RPC) recurring=$(cast call $RC 'recurringCount()(uint256)' --rpc-url $RPC)"
