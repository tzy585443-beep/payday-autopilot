#!/usr/bin/env bash
# Deploys Payday Autopilot: TestUSD (origin) -> PaydayReactive (Lasna) -> PaydayExecutor (destination) -> wiring.
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
WALLET=$DEPLOYER

say "Balances"
echo "Lasna   : $(cast balance $DEPLOYER --rpc-url $REACTIVE_RPC --ether) lREACT"
echo "Origin  : $(cast balance $DEPLOYER --rpc-url $ORIGIN_RPC --ether) ETH"
echo "Dest    : $(cast balance $DEPLOYER --rpc-url $DEST_RPC --ether) ETH"

TOKEN=$(jget token)
if [ -z "$TOKEN" ]; then
  say "Deploy TestUSD on origin ($ORIGIN_CHAIN_ID)"
  out=$(create $ORIGIN_RPC $PRIVATE_KEY 0 src/TestUSD.sol:TestUSD); echo "$out"
  TOKEN=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  jset token $TOKEN; jset token_tx $(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
fi

RC=$(jget reactive)
if [ -z "$RC" ]; then
  say "Deploy PaydayReactive on Lasna"
  out=$(create $REACTIVE_RPC $PRIVATE_KEY $REACTIVE_FUND src/PaydayReactive.sol:PaydayReactive \
    $ORIGIN_CHAIN_ID $DEST_CHAIN_ID $TOKEN $WALLET $MIN_INCOME $EMPLOYER $CRON_TOPIC $RECURRING_INTERVAL); echo "$out"
  RC=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  jset reactive $RC; jset reactive_tx $(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
fi

EX=$(jget executor)
if [ -z "$EX" ]; then
  say "Deploy PaydayExecutor on destination ($DEST_CHAIN_ID)"
  out=$(create $DEST_RPC $PRIVATE_KEY $EXECUTOR_FUND src/PaydayExecutor.sol:PaydayExecutor \
    $CALLBACK_PROXY $RC $TOKEN $SAVINGS $SAVE_BPS $MAX_SAVE_PER_DAY); echo "$out"
  EX=$(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['deployedTo'])")
  jset executor $EX; jset executor_tx $(echo "$out" | python3 -c "import json,sys;print(json.load(sys.stdin)['transactionHash'])")
fi

if [ -z "$(jget wire_tx)" ]; then
  say "Wire: setExecutor / approve / setRecurring"
  jset wire_tx $(send $REACTIVE_RPC $PRIVATE_KEY $RC "setExecutor(address)" $EX)
  jset approve_tx $(send $DEST_RPC $PRIVATE_KEY $TOKEN "approve(address,uint256)" $EX $(cast max-uint))
  jset gaslimit_tx $(send $REACTIVE_RPC $PRIVATE_KEY $RC "setCallbackGasLimit(uint64)" $CALLBACK_GAS_LIMIT)
  jset recurring_tx $(send $DEST_RPC $PRIVATE_KEY $EX "setRecurring(address,uint256,uint256)" $LANDLORD $RECURRING_AMOUNT $RECURRING_MIN_GAP)
fi

say "Done"; cat $DEPLOY_FILE
