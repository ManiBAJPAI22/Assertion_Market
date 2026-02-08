// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {UMAAssertionMarket} from "../src/UMAAssertionMarket.sol";

/// @title Deploy — Deploys UMAAssertionMarket to Sepolia using live UMA OO v3.
contract Deploy is Script {
    // Sepolia addresses
    address constant OO_V3 = 0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944;
    address constant WETH9 = 0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9;

    // Configuration
    uint64 constant LIVENESS = 7200; // 2 hours — standard dispute window
    uint256 constant BOND = 0.001 ether; // Explicit bond — OO v3 min for WETH on Sepolia is 0

    function run() external {
        vm.startBroadcast();

        UMAAssertionMarket market = new UMAAssertionMarket(OO_V3, WETH9, LIVENESS, BOND);

        console2.log("UMAAssertionMarket deployed at:", address(market));
        console2.log("OO v3:", OO_V3);
        console2.log("WETH9:", WETH9);
        console2.log("Liveness:", LIVENESS);
        console2.log("Bond:", BOND, "(0 = OO v3 minimum)");

        vm.stopBroadcast();
    }
}
