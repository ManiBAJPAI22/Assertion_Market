// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {UMAAssertionMarket} from "../src/UMAAssertionMarket.sol";
import {MockOptimisticOracleV3} from "../test/mocks/MockOptimisticOracleV3.sol";
import {WETH9} from "../test/mocks/WETH9.sol";

/// @title OracleSandbox — Deploys a sandboxed oracle environment + UMAAssertionMarket.
/// @notice Useful for testing on Sepolia without depending on live UMA DVM.
///         The MockOptimisticOracleV3 allows manual dispute resolution via resolveAssertion().
contract OracleSandbox is Script {
    uint256 constant MINIMUM_BOND = 0.001 ether; // Low bond for testing
    uint64 constant LIVENESS = 120; // 2 minutes for fast testing

    function run() external {
        vm.startBroadcast();

        // 1. Deploy WETH9
        WETH9 weth = new WETH9();
        console2.log("WETH9 deployed at:", address(weth));

        // 2. Deploy Mock OO v3
        MockOptimisticOracleV3 mockOO = new MockOptimisticOracleV3(MINIMUM_BOND);
        console2.log("MockOptimisticOracleV3 deployed at:", address(mockOO));

        // 3. Deploy UMAAssertionMarket with sandbox OO
        UMAAssertionMarket market = new UMAAssertionMarket(address(mockOO), address(weth), LIVENESS, MINIMUM_BOND);
        console2.log("UMAAssertionMarket (sandbox) deployed at:", address(market));
        console2.log("Liveness:", LIVENESS, "seconds");
        console2.log("Minimum Bond:", MINIMUM_BOND, "wei");

        vm.stopBroadcast();
    }
}
