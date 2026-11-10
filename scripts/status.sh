#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
TOKEN=$(jget token); RC=$(jget reactive); EX=$(jget executor)
echo "PaydayReactive $RC  lREACT=$(cast balance $RC --rpc-url $REACTIVE_RPC --ether) debt=$(cast call 0x8888888888888888888888888888888888888888 'debt(address)(uint256)' $RC --rpc-url $REACTIVE_RPC)"
echo "  incomeEvents=$(cast call $RC 'incomeEvents()(uint256)' --rpc-url $REACTIVE_RPC) ignored=$(cast call $RC 'ignoredEvents()(uint256)' --rpc-url $REACTIVE_RPC) recurring=$(cast call $RC 'recurringCount()(uint256)' --rpc-url $REACTIVE_RPC)"
echo "PaydayExecutor $EX  ETH=$(cast balance $EX --rpc-url $DEST_RPC --ether) debt=$(cast call $CALLBACK_PROXY 'debt(address)(uint256)' $EX --rpc-url $DEST_RPC)"
echo "  totalSaved=$(cast call $EX 'totalSaved()(uint256)' --rpc-url $DEST_RPC) totalPaid=$(cast call $EX 'totalPaid()(uint256)' --rpc-url $DEST_RPC)"
