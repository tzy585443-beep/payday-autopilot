# Payday Autopilot 💸⚡

**Pay yourself first, automatically.** Every time your paycheck lands in your wallet, a reactive contract on
[Reactive Network](https://reactive.network) notices it and moves your chosen percentage into savings. It can also
pay a recurring bill (rent, an allowance, a subscription, a weekly DCA buy) on a wall-clock schedule.
Nothing runs on your laptop and there are no keeper bots or cron servers. You set the rules once and leave it.

> Reactive Omni Buildathon, track **Set It and Forget It**. Live on testnet: **Ethereum Sepolia → Reactive Lasna → Ethereum Sepolia**
> (Base Sepolia supported via `config.env`).

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
 Eth Sepolia (origin)                Reactive Lasna                         Eth Sepolia (destination)
 ────────────────────                ──────────────                         ─────────────────────────
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
| [`PaydayExecutor`](src/PaydayExecutor.sol) | Destination (Ethereum Sepolia) | Authenticated callback receiver. Enforces savings %, daily cap, replay protection and the recurring rate limit, then moves tokens with `transferFrom`. |
| [`TestUSD`](src/TestUSD.sol) | Origin (Ethereum Sepolia) | 6-decimal test stablecoin with an open `mint` (testnet only). |

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

### Testnet deployment (Lasna + Ethereum Sepolia)

1. Put a **testnet-only** key in `.secrets` (git-ignored, `chmod 600`):
   ```
   PRIVATE_KEY=0x...
   DEPLOYER=0x...          # the wallet being automated
   EMPLOYER_KEY=0x...      # demo payer
   EMPLOYER=0x...
   SAVINGS=0x...           # where savings go
   LANDLORD=0x...          # recurring payee
   ```
2. Fund the deployer with Sepolia ETH (0.05 is plenty), then swap some for lREACT through Reactive's faucet contract:
   ```bash
   cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 "request(address)" $DEPLOYER \
     --value 0.025ether --rpc-url https://ethereum-sepolia-rpc.publicnode.com --private-key $PRIVATE_KEY   # → 2.5 lREACT
   ```
   (Base Sepolia faucet contract: `0x2afaFD298b23b62760711756088F75B7409f5967`.)
3. `./scripts/deploy.sh` deploys and wires everything and writes `deployments/testnet.json`.
4. `./scripts/demo.sh` runs a paycheck through the live loop. It prints the origin tx, the reactive tx on Lasna
   and the callback tx on Sepolia, measures the latency, and appends the hashes to `deployments/testnet.json`.
   `./scripts/demo-ignored.sh` shows an untrusted sender being filtered out.
5. `./scripts/status.sh` shows balances, debt and counters.

Every parameter (chains, callback proxy, %, cap, schedule) is in [`config.env`](config.env). There is a Lasna-only
variant as well (origin = destination = Lasna, proxy `0x8888…8888`).

## Deployed contracts & full-loop transactions (live, Nov 10 2026)

All three contracts are verified on Sourcify (exact match). Raw data: [`deployments/testnet.json`](deployments/testnet.json).

| Contract | Chain | Address |
| --- | --- | --- |
| PaydayReactive | Reactive Lasna (5318007) | [`0xC0ad86d5e599E1FBaF249F9aE44e727e4E37b172`](https://lasna.reactscan.net/address/0xC0ad86d5e599E1FBaF249F9aE44e727e4E37b172) |
| PaydayExecutor | Ethereum Sepolia (11155111) | [`0x89Be54A933d3b9e5c6E45365d859f33df5011EdF`](https://sepolia.etherscan.io/address/0x89Be54A933d3b9e5c6E45365d859f33df5011EdF) |
| TestUSD (tUSD) | Ethereum Sepolia (11155111) | [`0xC538D3954531F4AA695f27C2981117f146468102`](https://sepolia.etherscan.io/address/0xC538D3954531F4AA695f27C2981117f146468102) |

Watched wallet / owner: `0xB87535127cD89E54A6E9Fa8df3E5EA863bb1dB34`. Trusted payer: `0xc2072861d08bb7730e328699b70412C8046bAF0f`.
Savings: `0xa496D5D455d4cc3b9be8E5e068cbEAdB6Ef89a43`. Recurring payee: `0x4192546BBEB9E3bCe61aCe2C5369B58dB399dD1d`.

| Loop | Origin event (Sepolia) | Reactive tx (Lasna) | Callback (Sepolia) | Result | Latency* |
| --- | --- | --- | --- | --- | --- |
| Paycheck 3,000 | [`0x52b626c7…`](https://sepolia.etherscan.io/tx/0x52b626c7ae7a9fe1e63bf7b2b4978205e88951197179f95ab6e410f1403b95aa) | [`0xc10a71d4…`](https://lasna.reactscan.net/tx/0xc10a71d4747ecd55d92058040b85dd48db34c21027374d9062ad885674f73b29) | [`0x79aa8854…`](https://sepolia.etherscan.io/tx/0x79aa88548455a653b8aef86c65ba6888eb894455ce8f552959bab86c471143a3) | `Saved` 600 (20%) | 12.4 s / 23.6 s |
| Paycheck 6,000 | [`0xfaeaf5bd…`](https://sepolia.etherscan.io/tx/0xfaeaf5bd24fb9694c6190a4e3e1beb5c5d731a2d15ae522a50e0e0d33da64758) | [`0x91b09676…`](https://lasna.reactscan.net/tx/0x91b09676878b191f947ac4f997e794c63d1fb79e96ca64b971a6ab1a24b33fd0) | [`0xeaee6420…`](https://sepolia.etherscan.io/tx/0xeaee6420ce17fe0dc7429fd652f2706edc7bb24302e5834a9873a525931be0ac) | `Saved` 400 (daily cap 1,000 reached) | 12.4 s / 34.8 s |
| Rent via CRON (#2) | Lasna `Cron100` tick | [`0x3f6e8970…`](https://lasna.reactscan.net/tx/0x3f6e8970749c21e73071ad70eb05366ec8f08d95c8ff0ea8410c7e7e53368940) | [`0xcd1047ad…`](https://sepolia.etherscan.io/tx/0xcd1047ad22eb6aa90751fc0ff2f7526de62841742434e75e130c4f4c6a4ca907) | `RecurringPaid` 50 | n/a |
| Untrusted sender 500 | [`0xc7469ec8…`](https://sepolia.etherscan.io/tx/0xc7469ec85dfb5a8f5c3807957e850b8959644f221da9cb188053cfaddf776a7a) | [`0xc640e78c…`](https://lasna.reactscan.net/tx/0xc640e78c7bbc26d7e82cc4a85848c1b32d3714a14b13b16568a73e73d833bead) | none (by design) | `IncomeIgnored` | n/a |

\* Measured by `scripts/demo.sh` from submitting the origin tx (including its Sepolia inclusion) to seeing the
reactive tx on Lasna / the callback's `Saved` event on Sepolia. Both numbers include waiting for the origin tx to land in a ~12 s Sepolia block.

**Lesson learned (kept in the history on purpose).** The first loop
([`0xc69629e0…`](https://sepolia.etherscan.io/tx/0xc69629e091f99527eb114aa1549641c37ac919ff7d0a6b28d2f9ac550a5bd217) → [`0xd6597cdb…`](https://lasna.reactscan.net/tx/0xd6597cdb8a0a5069b2c92b1709954f3d7b4275315b1e5a3b2f15f8e3cb601465) →
[`0x9ed22231…`](https://sepolia.etherscan.io/tx/0x9ed22231e428d818c17dafdf080d462ccf79704954ede3ef307699b2697ac84b)) and the first CRON payment ended in `CallbackFailure`.
The 500k callback gas limit was too low: `onIncome` uses about 710k gas on Sepolia. Raising it to 1.5M with
`setCallbackGasLimit` ([`0x09b9802d…`](https://lasna.reactscan.net/tx/0x09b9802d9b480bc6b86734c27e834e09d954336fba6aeed406429ccf177f2192)) fixed it. Nothing was
moved and nothing was replayed. `deploy.sh` now sets `CALLBACK_GAS_LIMIT` from `config.env`.

After the demo, recurring payments were switched off ([`0x36d8edad…`](https://lasna.reactscan.net/tx/0x36d8edad17b70286efe417930e522ab1737f792c86be7d99f3fb54be0dc22c1a)).
That unsubscribes from CRON, so the contract stops paying for ticks. Income watching stays live.

## Costs

* Lasna: deploying `PaydayReactive` takes about 1.55 M gas (about 0.16 lREACT at 100 gwei). Each reactive tx costs
  `gasPrice × (gasUsed + 100k)`, about 0.015 to 0.02 lREACT.
* CRON ticks are billed whether or not a payment is due. Pick the longest interval that fits (Cron10000 is about
  3 h for monthly rent), or switch recurring off with `setRules(min, anyPayer, 0)` to unsubscribe.
* Callbacks are billed to `PaydayExecutor` in destination-chain ETH (negligible on Sepolia today: about 2×10⁻¹⁰ ETH for the first four callbacks). Top it up with `depositTo` on the proxy or
  send ETH and call `coverDebt()`.

## Security model

* `react()` checks `onlySystem`, plus origin chain, token, event signature, `opCode == 3` and `to == wallet`.
* Callbacks use `onlyServiceProvider` (the callback proxy) **and** `onlyCallbackSender` (our reactive contract).
* Money can only flow from the owner to two owner-configured addresses. It is capped per 24 h, replay-protected
  per origin log, and rate-limited for recurring payments.
* Revoke the token allowance to stop everything instantly. `pause()` on the reactive side stops all billing.

## License

MIT. See [LICENSE](LICENSE). Built during the Reactive Omni Buildathon (Nov 5 to Dec 5, 2026).
