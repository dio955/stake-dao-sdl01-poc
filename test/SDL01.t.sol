// SPDX-License-Identifier: MIT
// ============================================================================
// SD-L01 — `EpochCapNotSet` bricks CRV notify at every epoch rollover
//          until the delegation cap for the new epoch is set.
//
// Target   : CurveAccumulator (sdCRV) 0x11F78501e6b0cbc5DE4c7e6BBabaACdb973eb4Cd
//            Ethereum mainnet, Sourcify exact_match, Solidity 0.8.28.
//            Source used: work/sourcify-live/crv-acc.json (30 files, extracted
//            verbatim into src/ + node_modules/; fidelity proven by
//            test/Fidelity.t.sol — fresh deployment == live code modulo the
//            53-byte solc metadata trailer).
// Fork     : block 26,431,610 (2026-11-17T01:54:35Z), RPC
//            https://ethereum.publicnode.com (see foundry.toml [rpc_endpoints]).
// Run      : forge test --match-contract SDL01PoC -vv
// Severity : Low — liveness/delay only. No funds are lost or stolen: CRV stays
//            in the accumulator and can be notified once the cap is set.
//
// Root cause (live source, src/AccumulatorDelegable.sol):
//   L159-162  getDelegationCapBpsForEpoch() does
//                require(c != 0, EpochCapNotSet());
//   L106-110  _shareWithDelegation() reads the cap via that getter, then has
//                if (capBps != 0) { amount = amount * capBps / DENOMINATOR; }
//             i.e. 0 was MEANT to mean "no cap", but the getter reverts on 0,
//             so the `capBps != 0` branch is dead code and an unset cap bricks
//             the whole notify path.
//   Caller: src/integrations/curve/Accumulator.sol:93 (CurveAccumulator.
//             _notifyReward): `if (_tokenReward == token) _amount -=
//             _shareWithDelegation();` — the revert aborts the whole
//             claimAndNotifyAll() atomically, including the crvUSD notify
//             that already ran in the same tx.
//
// Seams (public, unprivileged — the attacker/caller is a fresh ordinary
// address, never owner/governance/multisig):
//   - CurveAccumulator.notifyReward(CRV)            (public, anyone)
//   - CurveAccumulator.claimAndNotifyAll()          (public, anyone)
// Control only (setter role, NOT the attack path):
//   - setDelegationCapBpsForEpoch() pranked as governance() — proves the cap
//     is the gate that opens/closes the path.
// Patched control:
//   - patched-src/ == live source with ONE change: the getter returns 0
//     instead of reverting. Etched over the live address (storage preserved)
//     to prove the fix works against the real gauge wiring.
// ============================================================================
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CurveAccumulator as PatchedCurveAccumulator} from "patched-src/integrations/curve/Accumulator.sol";

interface ICurveAccumulator {
    error EpochCapNotSet();

    function currentEpoch() external view returns (uint256);
    function getDelegationCapBpsForEpoch(uint256 epoch) external view returns (uint256);
    function delegationCapBpsForEpoch(uint256 epoch) external view returns (uint256);
    function notifyReward(address token) external;
    function claimAndNotifyAll() external;
    function governance() external view returns (address);
    function feeReceiver() external view returns (address);
    function veBoost() external view returns (address);
    function veBoostDelegation() external view returns (address);
    function locker() external view returns (address);
    function gauge() external view returns (address);
    function token() external view returns (address);
    function rewardToken() external view returns (address);
    function setDelegationCapBpsForEpoch(uint256 delegationCapBps, uint256 epoch) external;
    function isDelegationCapSetter(address who) external view returns (bool);
}

interface IVeBoost {
    function received_balance(address account) external returns (uint256);
    function balanceOf(address account) external returns (uint256);
}

interface ILiquidityGauge {
    struct Reward {
        address token;
        address distributor;
        uint256 period_finish;
        uint256 rate;
        uint256 last_update;
        uint256 integral;
    }

    function reward_data(address tokenReward) external view returns (Reward memory);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract SDL01PoC is Test {
    // --- Live addresses (registry + address-book, verified on-chain) ---
    address constant ACC = 0x11F78501e6b0cbc5DE4c7e6BBabaACdb973eb4Cd;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CRVUSD = 0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E;
    address constant GAUGE = 0x7f50786A0b15723D741727882ee99a0BF34e3466;
    address constant LOCKER = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;
    address constant VE_BOOST = 0xD37A6aa3d8460Bd2b6536d608103D880695A23CD;
    address constant VE_BOOST_DELEGATION = 0xe1F9C8ebBC80A013cAf0940fdD1A8554d763b9cf;
    address constant GATEWAY = 0xe5d6D047DF95c6627326465cB27B64A8b77A8b91;

    // --- Epochs (weekly, Thursday 00:00 UTC) ---
    uint256 constant EPOCH_NOW = 1794441600; // epoch live at the fork block
    uint256 constant EPOCH_NEXT = 1795046400; // first epoch after rollover
    uint256 constant DENOMINATOR = 1e18;
    uint256 constant WEEK = 604800;

    // --- Test constants ---
    uint256 constant DEAL_CRV = 1000 ether; // CRV dealt to the accumulator per test
    address CALLER; // ordinary unprivileged address (never owner/governance)

    ICurveAccumulator acc = ICurveAccumulator(ACC);

    function setUp() public {
        vm.createSelectFork("mainnet", 26431610);
        CALLER = makeAddr("ordinary-caller");
        // Selector sanity: the live revert must be exactly EpochCapNotSet().
        assertEq(ICurveAccumulator.EpochCapNotSet.selector, bytes4(0xf3ae9821));
    }

    // --- Helpers ---------------------------------------------------------

    function _boostReceived() internal returns (uint256) {
        return IVeBoost(VE_BOOST).received_balance(LOCKER);
    }

    function _lockerVeBalance() internal returns (uint256) {
        return IVeBoost(VE_BOOST).balanceOf(LOCKER);
    }

    /// @notice Log the live gauge CRV rate and the implied weekly flow.
    function _logLiveRate() internal view {
        ILiquidityGauge.Reward memory r = ILiquidityGauge(GAUGE).reward_data(CRV);
        console.log("gauge CRV distributor:", r.distributor);
        console.log("gauge CRV rate (wei/sec):", r.rate);
        console.log("gauge CRV period_finish:", r.period_finish);
        console.log("implied CRV/week at live rate:", r.rate * WEEK);
    }

    // --- 0. Baseline: the path works today (cap set for the live epoch) ---

    function test_00_baseline_notifyWorksWhileCapSet() public {
        assertEq(acc.currentEpoch(), EPOCH_NOW);
        uint256 capNow = acc.getDelegationCapBpsForEpoch(EPOCH_NOW);
        console.log("cap current epoch:", capNow);
        assertGt(capNow, 0);
        assertEq(acc.feeReceiver(), 0x60136fefE23D269aF41aB72DE483D186dC4318D6);

        uint256 boost = _boostReceived();
        console.log("veBoost received_balance(locker):", boost);
        assertGt(boost, 0, "precondition: locker receives boost");
        _logLiveRate();

        deal(CRV, ACC, DEAL_CRV);
        uint256 gaugeBefore = IERC20(CRV).balanceOf(GAUGE);
        uint256 delegationBefore = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION);

        vm.prank(CALLER);
        acc.notifyReward(CRV); // ordinary caller, cap set -> succeeds

        uint256 gaugeDelta = IERC20(CRV).balanceOf(GAUGE) - gaugeBefore;
        uint256 delegationDelta = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION) - delegationBefore;
        console.log("baseline: gauge received CRV:", gaugeDelta);
        console.log("baseline: delegation received CRV:", delegationDelta);
        assertGt(gaugeDelta, 0, "gauge got CRV");
        assertGt(delegationDelta, 0, "delegation got its share");
        assertEq(IERC20(CRV).balanceOf(ACC), 0, "accumulator drained its CRV");
    }

    // --- 1. ATTACK: notifyReward(CRV) reverts after rollover, cap unset ---

    function test_01_attack_notifyRewardRevertsEpochCapNotSet() public {
        vm.warp(EPOCH_NEXT);
        assertEq(acc.currentEpoch(), EPOCH_NEXT, "we are in the new epoch");

        // The cap for the new epoch was never set.
        vm.expectRevert(ICurveAccumulator.EpochCapNotSet.selector);
        acc.getDelegationCapBpsForEpoch(EPOCH_NEXT);

        // Preconditions for _shareWithDelegation() to reach the getter:
        // locker still receives boost after the warp, and accumulator holds CRV.
        uint256 boost = _boostReceived();
        console.log("after warp, veBoost received_balance(locker):", boost);
        assertGt(boost, 0, "precondition: boost still received in new epoch");

        deal(CRV, ACC, DEAL_CRV);
        uint256 gaugeBefore = IERC20(CRV).balanceOf(GAUGE);
        uint256 delegationBefore = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION);

        // ATTACK: any ordinary address calls the public notify — it reverts.
        vm.prank(CALLER);
        vm.expectRevert(ICurveAccumulator.EpochCapNotSet.selector);
        acc.notifyReward(CRV);

        // Impact: nothing moved. CRV is stuck in the accumulator (not lost),
        // the gauge got nothing new, the delegation got nothing.
        assertEq(IERC20(CRV).balanceOf(ACC), DEAL_CRV, "CRV stuck in accumulator");
        assertEq(IERC20(CRV).balanceOf(GAUGE), gaugeBefore, "gauge received nothing");
        assertEq(
            IERC20(CRV).balanceOf(VE_BOOST_DELEGATION),
            delegationBefore,
            "delegation received nothing"
        );
        _logLiveRate();
    }

    // --- 2. ATTACK: claimAndNotifyAll() reverts atomically (crvUSD too) ---

    function test_02_attack_claimAndNotifyAllRevertsAtomically() public {
        vm.warp(EPOCH_NEXT);
        assertEq(acc.currentEpoch(), EPOCH_NEXT);

        // Give the flow something to do: CRV in the accumulator, crvUSD
        // claimable in the locker (so the early `if (claimedToken == 0)
        // return;` is passed and the flow reaches the CRV notify).
        deal(CRV, ACC, DEAL_CRV);
        deal(CRVUSD, LOCKER, 100 ether);
        uint256 lockerCrvUsdBefore = IERC20(CRVUSD).balanceOf(LOCKER);
        uint256 gaugeCrvUsdBefore = IERC20(CRVUSD).balanceOf(GAUGE);
        uint256 gaugeCrvBefore = IERC20(CRV).balanceOf(GAUGE);

        // ATTACK: any ordinary address calls the public entry point.
        vm.prank(CALLER);
        vm.expectRevert(ICurveAccumulator.EpochCapNotSet.selector);
        acc.claimAndNotifyAll();

        // Atomicity: the revert rolls back the crvUSD notify that ran
        // first in the same tx, so the gauge got neither token.
        assertEq(IERC20(CRVUSD).balanceOf(LOCKER), lockerCrvUsdBefore, "crvUSD still in locker");
        assertEq(IERC20(CRVUSD).balanceOf(GAUGE), gaugeCrvUsdBefore, "gauge got no crvUSD");
        assertEq(IERC20(CRV).balanceOf(GAUGE), gaugeCrvBefore, "gauge got no CRV");
        assertEq(IERC20(CRV).balanceOf(ACC), DEAL_CRV, "CRV still in accumulator");
    }

    // --- 3. CONTROL: setting the cap (governance prank, control only) re-opens the path ---

    function test_03_control_setCapThenNotifySucceeds() public {
        vm.warp(EPOCH_NEXT);
        assertEq(acc.currentEpoch(), EPOCH_NEXT);

        // CONTROL ONLY: prank the on-chain governance (authorized by
        // onlyDelegationCapSetterOrGovernance) to set the new epoch's cap.
        // This is NOT the attack path — it proves the cap is the gate.
        address gov = acc.governance();
        uint256 capNow = acc.delegationCapBpsForEpoch(EPOCH_NOW);
        vm.prank(gov);
        acc.setDelegationCapBpsForEpoch(capNow, EPOCH_NEXT);
        assertEq(acc.getDelegationCapBpsForEpoch(EPOCH_NEXT), capNow);

        deal(CRV, ACC, DEAL_CRV);
        uint256 gaugeBefore = IERC20(CRV).balanceOf(GAUGE);
        uint256 delegationBefore = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION);

        vm.prank(CALLER);
        acc.notifyReward(CRV); // same call as the attack — now succeeds

        uint256 gaugeDelta = IERC20(CRV).balanceOf(GAUGE) - gaugeBefore;
        uint256 delegationDelta = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION) - delegationBefore;
        console.log("control: gauge received CRV:", gaugeDelta);
        console.log("control: delegation received CRV:", delegationDelta);
        assertGt(gaugeDelta, 0);
        assertGt(delegationDelta, 0);

        // The delegation share must follow the contract's own math, computed
        // here from live chain state (not from the contract's outputs), in
        // the contract's exact order of operations (division order matters):
        //   bpsDelegated = boostReceived * 1e18 / lockerVeBalance
        //   capped       = DEAL_CRV * cap / 1e18
        //   share        = capped * bpsDelegated / 1e18
        // (feeReceiver.split(CRV) moves no CRV out of the accumulator here:
        //  gaugeDelta + delegationDelta == DEAL_CRV, asserted below.)
        assertEq(gaugeDelta + delegationDelta, DEAL_CRV, "all dealt CRV accounted for");
        uint256 bpsDelegated = (_boostReceived() * DENOMINATOR) / _lockerVeBalance();
        uint256 expectedShare = ((DEAL_CRV * capNow) / DENOMINATOR * bpsDelegated) / DENOMINATOR;
        assertEq(delegationDelta, expectedShare, "delegation share matches live-state math");
    }

    // --- 4. PATCHED CONTROL: getter returns 0 (no revert) -> notify works without any cap ---

    function test_04_patched_getterReturnsZeroNotifySucceeds() public {
        vm.warp(EPOCH_NEXT);
        assertEq(acc.currentEpoch(), EPOCH_NEXT);
        // Cap for the new epoch is still unset on the live storage.
        assertEq(acc.delegationCapBpsForEpoch(EPOCH_NEXT), 0);

        // Deploy the patched build (ONE change vs live: the getter returns 0
        // instead of reverting) and etch its runtime code over the live
        // accumulator address, preserving live storage + gauge wiring.
        address gov = acc.governance();
        PatchedCurveAccumulator patched = new PatchedCurveAccumulator(GAUGE, LOCKER, gov, GATEWAY);
        bytes memory liveCodeBefore = ACC.code;
        vm.etch(ACC, address(patched).code);
        assertEq(keccak256(ACC.code), keccak256(address(patched).code), "etched patched code");
        assertTrue(keccak256(ACC.code) != keccak256(liveCodeBefore), "code actually changed");

        // The patched getter returns 0 instead of reverting.
        assertEq(acc.getDelegationCapBpsForEpoch(EPOCH_NEXT), 0);

        deal(CRV, ACC, DEAL_CRV);
        uint256 gaugeBefore = IERC20(CRV).balanceOf(GAUGE);
        uint256 delegationBefore = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION);

        // Same ordinary caller, same call as the attack, no cap set anywhere.
        vm.prank(CALLER);
        acc.notifyReward(CRV); // succeeds on patched code

        uint256 gaugeDelta = IERC20(CRV).balanceOf(GAUGE) - gaugeBefore;
        uint256 delegationDelta = IERC20(CRV).balanceOf(VE_BOOST_DELEGATION) - delegationBefore;
        console.log("patched: gauge received CRV:", gaugeDelta);
        console.log("patched: delegation received CRV:", delegationDelta);
        assertGt(gaugeDelta, 0);
        assertGt(delegationDelta, 0);
        assertEq(gaugeDelta + delegationDelta, DEAL_CRV, "all dealt CRV accounted for");

        // With cap 0 the fix treats it as "uncapped": share == the share a
        // cap of 1e18 would give, in the contract's exact order of operations:
        //   bpsDelegated = boostReceived * 1e18 / lockerVeBalance
        //   share        = DEAL_CRV * bpsDelegated / 1e18
        uint256 bpsDelegated = (_boostReceived() * DENOMINATOR) / _lockerVeBalance();
        uint256 expectedShare = (DEAL_CRV * bpsDelegated) / DENOMINATOR;
        assertEq(delegationDelta, expectedShare, "patched share == uncapped share");
    }
}
