#!/usr/bin/env bash
# Live demo on testnet: employer pays the wallet -> Lasna reacts -> executor saves 20% on the destination chain.
source "$(dirname "$0")/lib.sh"
TOKEN=$(jget token); RC=$(jget reactive); EX=$(jget executor)
AMOUNT=${1:-3000000000} # 3,000 tUSD

bal() { cast call $TOKEN "balanceOf(address)(uint256)" $1 --rpc-url $DEST_RPC | awk '{print $1/1e6}'; }

if [ "$(cast balance $EMPLOYER --rpc-url $ORIGIN_RPC)" = "0" ]; then
  say "Fund employer with gas"; send $ORIGIN_RPC $PRIVATE_KEY $EMPLOYER --value 0.0005ether >/dev/null
fi
send $ORIGIN_RPC $PRIVATE_KEY $TOKEN "mint(address,uint256)" $EMPLOYER $AMOUNT >/dev/null

say "Before: wallet=$(bal $DEPLOYER) savings=$(bal $SAVINGS) rent=$(bal $LANDLORD) tUSD"
say "1) Employer pays $(($AMOUNT/1000000)) tUSD to the wallet on chain $ORIGIN_CHAIN_ID"
T0=$(date +%s.%N)
TX=$(send $ORIGIN_RPC $EMPLOYER_KEY $TOKEN "transfer(address,uint256)" $DEPLOYER $AMOUNT)
echo "origin tx: $TX"
FROM_BLOCK=$(cast block-number --rpc-url $REACTIVE_RPC)

say "2) Waiting for PaydayReactive on Lasna (IncomeDetected) ..."
SIG=$(cast keccak "IncomeDetected(address,uint256,uint256,uint256)")
for i in $(seq 1 120); do
  L=$(cast logs --json --rpc-url $REACTIVE_RPC --from-block $FROM_BLOCK --address $RC $SIG 2>/dev/null || echo '[]')
  RTX=$(echo "$L" | python3 -c "import json,sys;l=json.load(sys.stdin);print(l[-1]['transactionHash'] if l else '')")
  [ -n "$RTX" ] && break; sleep 1
done
T1=$(date +%s.%N); echo "reactive tx (Lasna): $RTX"

say "3) Waiting for the callback on chain $DEST_CHAIN_ID (Saved) ..."
SSIG=$(cast keccak "Saved(uint256,address,uint256,uint256,uint256)")
DFROM=$(( $(cast block-number --rpc-url $DEST_RPC) - 300 )); [ $DFROM -lt 0 ] && DFROM=0
for i in $(seq 1 180); do
  L=$(cast logs --json --rpc-url $DEST_RPC --from-block $DFROM --address $EX $SSIG $TX 2>/dev/null || echo '[]')
  CTX=$(echo "$L" | python3 -c "import json,sys;l=json.load(sys.stdin);print(l[-1]['transactionHash'] if l else '')")
  [ -n "$CTX" ] && break; sleep 1
done
T2=$(date +%s.%N); echo "callback tx (dest): $CTX"
python3 -c "print('observed latency: origin->reactive %.1fs, origin->callback %.1fs' % ($T1-$T0, $T2-$T0))"

say "After: wallet=$(bal $DEPLOYER) savings=$(bal $SAVINGS) rent=$(bal $LANDLORD) tUSD"
echo "callbacks recorded by system contract:"
cast call 0x8888888888888888888888888888888888888888 "getCallbacks(uint256)((uint256,address,uint256,uint256,uint256,bytes)[])" $RTX --rpc-url $REACTIVE_RPC || true
python3 - "$TX" "$RTX" "$CTX" <<'P'
import json,os,sys,time
f=os.environ['DEPLOY_FILE'];d=json.load(open(f));d.setdefault('loops',[]).append({'origin_tx':sys.argv[1],'reactive_tx':sys.argv[2],'callback_tx':sys.argv[3],'at':int(time.time())});json.dump(d,open(f,'w'),indent=2)
P
