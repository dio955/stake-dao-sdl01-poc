// SPDX-License-Identifier: MIT
// Scratch fidelity check (NOT part of the PoC verdict): compile the Sourcify
// exact_match sources and compare the fresh deployment's runtime code with
// the live deployed code at the pinned fork block.
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {CurveAccumulator} from "src/integrations/curve/Accumulator.sol";

interface IAccGov {
    function governance() external view returns (address);
}

contract FidelityTest is Test {
    address constant ACC = 0x11F78501e6b0cbc5DE4c7e6BBabaACdb973eb4Cd;
    address constant GAUGE = 0x7f50786A0b15723D741727882ee99a0BF34e3466;
    address constant LOCKER = 0x52f541764E6e90eeBc5c21Ff570De0e2D63766B6;
    address constant GATEWAY = 0xe5d6D047DF95c6627326465cB27B64A8b77A8b91;

    function test_bytecodeMatchesLive() public {
        vm.createSelectFork("mainnet", 26431610);
        address gov = IAccGov(ACC).governance();
        console.log("live governance:", gov);
        CurveAccumulator fresh = new CurveAccumulator(GAUGE, LOCKER, gov, GATEWAY);
        bytes memory liveCode = ACC.code;
        bytes memory freshCode = address(fresh).code;
        console.log("live code len:", liveCode.length, "fresh code len:", freshCode.length);
        console.log("live code hash:", vm.toString(keccak256(liveCode)));
        console.log("fresh code hash:", vm.toString(keccak256(freshCode)));
        // solc 0.8.28 appends a 53-byte CBOR metadata hash; strip it before comparing.
        assertEq(liveCode.length, freshCode.length, "code length differs");
        bytes memory liveStripped = _stripMetadata(liveCode);
        bytes memory freshStripped = _stripMetadata(freshCode);
        assertEq(keccak256(liveStripped), keccak256(freshStripped), "code differs beyond metadata");
    }

    function _stripMetadata(bytes memory code) internal pure returns (bytes memory) {
        // CBOR metadata trailer: 0xa2 0x64 'ipfs' 0x58 0x22 <34 bytes> 0x64 'solc' 0x43 <3 bytes> 0x00 0x33
        // = 2 + 34 + 2 + 4 + 2 = 53 bytes total for solc 0.8.28.
        uint256 n = code.length - 53;
        bytes memory out = new bytes(n);
        for (uint256 i; i < n; i++) out[i] = code[i];
        return out;
    }
}
