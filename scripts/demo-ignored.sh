#!/usr/bin/env bash
# Live: a transfer from an untrusted sender reaches react() but is filtered out (no callback, no money moved).
source "$(dirname "$0")/lib.sh"
TOKEN=$(jget token); RC=$(jget reactive)
send $ORIGIN_RPC $PRIVATE_KEY $TOKEN "mint(address,uint256)" $LANDLORD 500000000 >/dev/null
if [ "$(cast balance $LANDLORD --rpc-url $ORIGIN_RPC)" = "0" ]; then send $ORIGIN_RPC $PRIVATE_KEY $LANDLORD --value 0.0003ether >/dev/null; fi
say "Untrusted address $LANDLORD sends 500 tUSD to the wallet"
FROM=$(cast block-number --rpc-url $REACTIVE_RPC)
TX=$(send $ORIGIN_RPC $LANDLORD_KEY $TOKEN "transfer(address,uint256)" $DEPLOYER 500000000); echo "origin tx: $TX"
SIG=$(cast keccak "IncomeIgnored(address,uint256,uint8)")
for i in $(seq 1 120); do
  RTX=$(cast logs --json --rpc-url $REACTIVE_RPC --from-block $FROM --address $RC $SIG | python3 -c "import json,sys;l=json.load(sys.stdin);print(l[-1]['transactionHash'] if l else '')")
  [ -n "$RTX" ] && break; sleep 1
done
echo "reactive tx (Lasna): $RTX  -> IncomeIgnored(reason=2 untrusted payer), no callback requested"
echo "ignoredEvents=$(cast call $RC 'ignoredEvents()(uint256)' --rpc-url $REACTIVE_RPC)"
jset ignored_origin_tx $TX; jset ignored_reactive_tx $RTX
