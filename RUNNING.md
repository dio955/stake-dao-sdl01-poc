# SD-L01 — PoC: `EpochCapNotSet` bricks CRV notify at epoch rollover

**Finding:** `CurveAccumulator.notifyReward(CRV)` (and therefore the whole
`claimAndNotifyAll()`) reverts with `EpochCapNotSet()` whenever the delegation
cap for the current epoch has not been set yet — i.e. in the window between
each weekly epoch rollover (Thursday 00:00 UTC) and the manual cap-set tx.

**Target:** `CurveAccumulator` (sdCRV)
`0x11F78501e6b0cbc5DE4c7e6BBabaACdb973eb4Cd`, Ethereum mainnet,
Sourcify `exact_match`, Solidity 0.8.28.

**Fork:** block **26,431,610** (2026-11-17T01:54:35Z),
RPC `https://ethereum.publicnode.com` (see `foundry.toml` `[rpc_endpoints]`).

**Root cause** (live source, `src/AccumulatorDelegable.sol`):
- `getDelegationCapBpsForEpoch()` (L159–162) does
  `require(c != 0, EpochCapNotSet())`.
- `_shareWithDelegation()` (L106–110) reads the cap through that getter, then
  has `if (capBps != 0) { amount = amount * capBps / DENOMINATOR; }` —
  i.e. **0 was meant to mean "no cap"**, but the getter reverts on 0, so the
  `capBps != 0` branch is dead code and an unset cap bricks the notify path.
- Caller: `src/integrations/curve/Accumulator.sol:93`
  (`CurveAccumulator._notifyReward`):
  `if (_tokenReward == token) _amount -= _shareWithDelegation();`

**Severity: Low — liveness/delay only.** No funds are lost or stolen: CRV
stays in the accumulator and can be notified once the cap is set. The
revert also rolls back the crvUSD notify that ran first in the same
`claimAndNotifyAll()` tx (atomicity — proven by `test_02`).

## Contents

| Path | What it is |
| --- | --- |
| `foundry.toml` | solc 0.8.28, optimizer runs 200, evm cancun, remappings, public RPC endpoints. No absolute paths — runnable from anywhere. |
| `test/SDL01.t.sol` | The PoC: 5 tests (baseline + 2 attacks + control + patched control). |
| `test/Fidelity.t.sol` | Fidelity check: fresh deployment of the extracted live source has byte-identical runtime code to the live contract (modulo the 53-byte solc metadata trailer). |
| `src/`, `node_modules/` | Live sources, extracted verbatim from `../work/sourcify-live/crv-acc.json` (Sourcify `exact_match`, 30 files). Only the files the accumulator needs. |
| `patched-src/` | Live source with **exactly one change**: `getDelegationCapBpsForEpoch()` returns 0 instead of reverting (the proposed fix). Imports rewritten `src/` → `patched-src/`; everything else identical. |
| `lib/forge-std/` | forge-std 1.17.0, vendored (no `forge install` / network needed). |

## How to run

Prerequisites: Foundry (`forge` 1.9.0 used; any recent 1.x works) and
internet access to `https://ethereum.publicnode.com` (fork RPC). No
accounts, keys, or sign-ins needed. Nothing touches mainnet — local fork only.

```bash
# from this directory (poc/sdl01/)
forge test -vv
# just the PoC contract:
forge test --match-contract SDL01PoC -vv
```

## Observed output (17 Nov 2026, forge 1.9.0, solc 0.8.28)

```
Ran 5 tests for test/SDL01.t.sol:SDL01PoC
[PASS] test_00_baseline_notifyWorksWhileCapSet() (gas: 615504)
Logs:
  cap current epoch: 996593311941337533
  veBoost received_balance(locker): 61802380229306646541889550
  gauge CRV distributor: 0x11F78501e6b0cbc5DE4c7e6BBabaACdb973eb4Cd
  gauge CRV rate (wei/sec): 20269254235940894
  gauge CRV period_finish: 1795149107
  implied CRV/week at live rate: 12258844961897052691200
  baseline: gauge received CRV: 657146541277805518891
  baseline: delegation received CRV: 342853458722194481109

[PASS] test_01_attack_notifyRewardRevertsEpochCapNotSet() (gas: 490300)
Logs:
  after warp, veBoost received_balance(locker): 61650054181245612434284800
  gauge CRV rate (wei/sec): 20269254235940894
  gauge CRV period_finish: 1795149107
  implied CRV/week at live rate: 12258844961897052691200

[PASS] test_02_attack_claimAndNotifyAllRevertsAtomically() (gas: 1093839)
[PASS] test_03_control_setCapThenNotifySucceeds() (gas: 703288)
Logs:
  control: gauge received CRV: 657402182749908653083
  control: delegation received CRV: 342597817250091346917

[PASS] test_04_patched_getterReturnsZeroNotifySucceeds() (gas: 2754553)
Logs:
  patched: gauge received CRV: 656231069238544438000
  patched: delegation received CRV: 343768930761455562000

Suite result: ok. 5 passed; 0 failed; 0 skipped

Ran 2 test suites: 6 tests passed; 0 failed; 0 skipped
(the 6th test is test/Fidelity.t.sol::test_bytecodeMatchesLive)
```

## What each test proves

| Test | Result |
| --- | --- |
| `test_00_baseline_notifyWorksWhileCapSet` | Sanity: at the fork block, with the current epoch's cap set (996593311941337533), an ordinary caller can `notifyReward(CRV)`; 1,000 dealt CRV split 657.15 → gauge, 342.85 → veBoost delegation. The fork setup and the path are sound. |
| `test_01_attack_notifyRewardRevertsEpochCapNotSet` | **ATTACK.** Warp to the new epoch start (1795046400). The new epoch's cap is unset (`getDelegationCapBpsForEpoch` reverts). Precondition still holds after the warp: `veBoost.received_balance(locker)` = 6.165e25 > 0. An ordinary unprivileged caller (`makeAddr("ordinary-caller")`, never owner/governance) calls `notifyReward(CRV)` → reverts `EpochCapNotSet()` (selector `0xf3ae9821`). All 1,000 CRV stay stuck in the accumulator; gauge and delegation receive nothing. |
| `test_02_attack_claimAndNotifyAllRevertsAtomically` | **ATTACK.** Same warp; `claimAndNotifyAll()` (public, ordinary caller) reverts `EpochCapNotSet()`. The revert rolls back the crvUSD notify that already ran in the same tx: locker crvUSD balance unchanged, gauge receives neither crvUSD nor CRV. |
| `test_03_control_setCapThenNotifySucceeds` | **CONTROL.** Same warp, but the on-chain `governance()` address (authorized by `onlyDelegationCapSetterOrGovernance`) is pranked **only as a control** to set the new epoch's cap to the current value. The identical `notifyReward(CRV)` call from the same ordinary caller now succeeds (gauge 657.40 CRV, delegation 342.60 CRV). The delegation share equals the value computed independently from live chain state (`boostReceived`, locker ve balance, cap) in the contract's exact order of operations. Proves the cap — and only the cap — opens/closes the path. |
| `test_04_patched_getterReturnsZeroNotifySucceeds` | **PATCHED CONTROL.** The patched build (getter returns 0 instead of reverting) is etched over the live accumulator address, preserving live storage and gauge wiring. With **no cap set anywhere**, the same ordinary-caller `notifyReward(CRV)` succeeds (gauge 656.23 CRV, delegation 343.77 CRV). The share equals the uncapped share (cap = 1e18 equivalent). Proves the proposed fix works and the PoC distinguishes vulnerable from patched code. |
| `test_bytecodeMatchesLive` (Fidelity) | The extracted live source compiles to runtime code identical to the deployed contract (8,456 bytes; only the 53-byte solc metadata trailer differs). The PoC tests the real code. |

## Quantified impact (measured live at fork block 26,431,610)

- Gauge CRV reward rate: **20,269,254,235,940,894 wei/s ≈ 2.03e16 CRV/s**.
- Implied flow through the bricked path: **12,258.84 CRV/week**
  (`rate × 604800` = 12,258,844,961,897,052,691,200 wei).
- Current reward period ends 1795149107 (~20 Nov 2026).
- **Delay, not loss:** every rollover window (Thursday 00:00 UTC until the
  cap-setter tx) blocks the whole weekly CRV distribution to the sdCRV
  gauge — and, via atomicity, the crvUSD distribution in the same
  `claimAndNotifyAll()` tx. The CRV/crvUSD stay in the accumulator and can
  be notified after the cap is set. The length of each window depends on the
  setter's cadence (manual, weekly); it is not measurable from chain state.
- No attacker profit: this is a liveness/griefing-by-omission issue, not a
  theft. Anyone can trigger the revert only by *calling* notify — the
  damage is the *inability* to notify until the setter acts.

## Honest caveats (for the report)

1. **Triage may close this as "intended gating."** Weekly cap-setting is a
   documented role (`isDelegationCapSetter`); the team operates a weekly
   set-cap cadence and the path works today. The finding is that the *code*
   contradicts its own intent (dead `capBps != 0` branch) and turns a
   missed/late manual step into a total, atomic brick of both reward
   notifies — a robustness/liveness issue, Low severity.
2. **Setter identity not recovered.** Free RPCs block the log query needed
   to find who set the last cap (publicnode: archive requests need a token;
   drpc: range limits; Ankr: API key). The control therefore pranks the
   on-chain `governance()` address (`0xB0552b6860CE5C0202976Db056b5e3Cc4f9CC765`,
   the Stake DAO governance Safe), which is equally authorized by
   `onlyDelegationCapSetterOrGovernance`. The control's conclusion (cap is
   the gate) does not depend on which authorized address sets it.
3. **No mainnet execution, no real funds.** All tests run on a local Foundry
   fork; CRV is dealt via the `deal` cheatcode. No sign-ins, no submissions.
4. **Clean-copy note:** the task asked for the clean-copy check in `/tmp`,
   but `/tmp` on this VM is 100% full (512 MB tmpfs). The clean-copy
   verification was done in `~/workspace/stakedao-audit/poc/.clean-copy-test/`
   instead (same procedure: unzip, `forge test`).

## Clean-copy verification

```bash
cd ~/workspace/stakedao-audit
unzip -o sdl01-poc.zip -d poc/.clean-copy-test/
cd poc/.clean-copy-test/sdl01   # (zip root is the poc/sdl01/ directory)
forge test -vv
# expected: 6 passed, 0 failed (5 PoC + 1 fidelity)
```
