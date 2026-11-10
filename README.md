# Payday Autopilot 💸⚡

**Pay yourself first, automatically.** Every time your paycheck lands in your wallet, a reactive contract on
[Reactive Network](https://reactive.network) notices it and moves your chosen percentage into savings. It can also
pay a recurring bill (rent, an allowance, a subscription, a weekly DCA buy) on a wall-clock schedule.
Nothing runs on your laptop and there are no keeper bots or cron servers. You set the rules once and leave it.

> Reactive Omni Buildathon, track **Set It and Forget It**. Testnet: Reactive **Lasna** + **Base Sepolia**.

## Why this is useful

"Save 20% of every paycheck" is one of the most common pieces of personal-finance advice, and one of the least
followed. Banks automate it with standing orders. On-chain, the usual answer is to do it by hand or run a bot.
Payday Autopilot puts the rule on-chain, and the user can audit and cap it:

* **Event-driven, not polling.** The sweep fires because the income arrived, not because a timer guessed it might have.
* **Filters real income only.** Payers must be on a trusted list (employer, client) and transfers must clear a
  minimum size. Airdrops, spam and dust don't move your money.
* **Bounded risk.** The executor only holds an ERC-20 allowance. It can only send to *your* savings address and
  *your* payee, it is capped per 24 h, and it has replay protection. Rules are owner-only and can change any time.
* **Recurring payments without a server.** Reactive's built-in CRON ticks plus a timestamp schedule. Per the
  Base Sepolia guidance, timers use timestamps, never block counts. Turning recurring off unsubscribes from CRON,
  so you stop paying for ticks.

## How it works

```
 Base Sepolia (origin)               Reactive Lasna                         Base Sepolia (destination)
 ─────────────────────               ──────────────                         ──────────────────────────
 Employer ── tUSD.transfer ──▶ Transfer(from, to=wallet, amount)
                                     │  subscription: token + topic0=Transfer + topic2=wallet
                                     ▼
                              PaydayReactive.react(log)
                              • right chain / token / opCode?
                              • payer trusted? amount ≥ minIncome?
                              • SYSTEM.requestCallbackV_1_0(...) ────▶  Callback proxy ──▶ PaydayExecutor.onIncome()
                                                                         • onlyServiceProvider + onlyCallbackSender
 Reactive CRON (Cron100) ────▶ react(): recurring due? (timestamp)       • replay key (originTx, logIndex)
                              • SYSTEM.requestCallbackV_1_0(...) ────▶   • save bps, 24 h cap → transferFrom(wallet → savings)
                                                                         PaydayExecutor.onRecurring() → transferFrom(wallet → payee)
```

| Contract | Chain | Role |
| --- | --- | --- |
| [`PaydayReactive`](src/PaydayReactive.sol) | Reactive (Lasna) | Subscribes to `Transfer(*, wallet, *)` on the origin chain and to CRON. Applies the income filters and the schedule, then requests callbacks. |
| [`PaydayExecutor`](src/PaydayExecutor.sol) | Destination (Base Sepolia) | Authenticated callback receiver. Enforces savings %, daily cap, replay protection and the recurring rate limit, then moves tokens with `transferFrom`. |
| [`TestUSD`](src/TestUSD.sol) | Origin (Base Sepolia) | 6-decimal test stablecoin with an open `mint` (testnet only). |

Built on Reactive **Omni** APIs: [`reactive-lib-omni`](https://github.com/Reactive-Network/reactive-lib-omni)
(`AbstractReactive`, `AbstractCallback`), `SYSTEM.subscribe` and `SYSTEM.requestCallbackV_1_0`. There is no `vm`
modifier and no RVM.

### Design notes

* `react()` never reverts as a filter. Reverts are still billed, so non-matching logs just return.
* The executor never reverts on a failed token pull (missing allowance or balance). It emits `Skipped(reason)`,
  because failed callbacks are billed too.
* The subscription is narrowed on-node with `topic2 = wallet`, so unrelated transfers of the token never cost anything.
* Deploy order follows the docs: reactive → executor(reactive address) → `setExecutor` (set once).

## Quick start

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
git clone --recursive <this repo> && cd payday-autopilot
forge build
forge test -vv             # 15 tests incl. fuzzing: full loop, filters, cap, replay, CRON, auth, pause
./scripts/local-sim.sh     # full loop on a local anvil node with a mock system contract (no funds needed)
```

### Testnet deployment (Lasna + Base Sepolia)

1. Put a **testnet-only** key in `.secrets` (git-ignored, `chmod 600`):
   ```
   PRIVATE_KEY=0x...
   DEPLOYER=0x...          # the wallet being automated
   EMPLOYER_KEY=0x...      # demo payer
   EMPLOYER=0x...
   SAVINGS=0x...           # where savings go
   LANDLORD=0x...          # recurring payee
   ```
2. Fund the deployer with Base Sepolia ETH (about 0.05), then swap some for lREACT through Reactive's faucet contract:
   ```bash
   cast send 0x2afaFD298b23b62760711756088F75B7409f5967 "request(address)" $DEPLOYER \
     --value 0.02ether --rpc-url https://sepolia.base.org --private-key $PRIVATE_KEY   # → 2 lREACT on Lasna
   ```
3. `./scripts/deploy.sh` deploys and wires everything and writes `deployments/testnet.json`.
4. `./scripts/demo.sh` runs a paycheck through the live loop. It prints the origin tx, the reactive tx on Lasna
   and the callback tx on Base Sepolia, measures the latency, and appends the hashes to `deployments/testnet.json`.
5. `./scripts/status.sh` shows balances, debt and counters.

Every parameter (chains, callback proxy, %, cap, schedule) is in [`config.env`](config.env). There is a Lasna-only
variant as well (origin = destination = Lasna, proxy `0x8888…8888`).

## Deployed contracts & full-loop transactions

See [`deployments/testnet.json`](deployments/testnet.json).

| Item | Address / tx |
| --- | --- |
| TestUSD (Base Sepolia) | _pending_ |
| PaydayReactive (Lasna) | _pending_ |
| PaydayExecutor (Base Sepolia) | _pending_ |
| Loop #1: origin tx → reactive tx → callback tx | _pending_ |

Explorers: [Lasna Reactscan](https://lasna.reactscan.net) · [Base Sepolia](https://sepolia.basescan.org)

## Costs

* Lasna: deploying `PaydayReactive` takes about 1.55 M gas (about 0.16 lREACT at 100 gwei). Each reactive tx costs
  `gasPrice × (gasUsed + 100k)`, about 0.015 to 0.02 lREACT.
* CRON ticks are billed whether or not a payment is due. Pick the longest interval that fits (Cron10000 is about
  3 h for monthly rent), or switch recurring off with `setRules(min, anyPayer, 0)` to unsubscribe.
* Callbacks are billed to `PaydayExecutor` in destination-chain ETH. Top it up with `depositTo` on the proxy or
  send ETH and call `coverDebt()`.

## Security model

* `react()` checks `onlySystem`, plus origin chain, token, event signature, `opCode == 3` and `to == wallet`.
* Callbacks use `onlyServiceProvider` (the callback proxy) **and** `onlyCallbackSender` (our reactive contract).
* Money can only flow from the owner to two owner-configured addresses. It is capped per 24 h, replay-protected
  per origin log, and rate-limited for recurring payments.
* Revoke the token allowance to stop everything instantly. `pause()` on the reactive side stops all billing.

## License

MIT. See [LICENSE](LICENSE). Built during the Reactive Omni Buildathon (Nov 5 to Dec 5, 2026).
