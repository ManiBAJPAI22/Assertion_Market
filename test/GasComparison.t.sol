// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {UMAAssertionMarket} from "../src/UMAAssertionMarket.sol";
import {UMAAssertionMarketNaive} from "./NaiveBaseline.sol";
import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";
import {WETH9} from "./mocks/WETH9.sol";

/// @title Gas Comparison: Optimized vs Naive (Unoptimized) baseline
/// @notice Runs identical operations on both contracts to measure gas savings.
contract GasComparisonTest is Test {
    UMAAssertionMarket public optimized;
    UMAAssertionMarketNaive public naive;
    MockOptimisticOracleV3 public mockOO1;
    MockOptimisticOracleV3 public mockOO2;
    WETH9 public weth;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    uint64  constant LIVENESS = 7200;
    uint256 constant BOND = 0.1 ether;
    uint256 constant MARKET = 1 ether;
    bytes   constant CLAIM = "Test claim for gas comparison";

    function setUp() public {
        weth = new WETH9();
        // Separate mock OO for each contract to avoid assertionId collisions
        mockOO1 = new MockOptimisticOracleV3(BOND);
        mockOO2 = new MockOptimisticOracleV3(BOND);
        optimized = new UMAAssertionMarket(address(mockOO1), address(weth), LIVENESS, BOND);
        naive = new UMAAssertionMarketNaive(address(mockOO2), address(weth), LIVENESS, BOND);

        vm.deal(user1, 100 ether);
        vm.deal(user2, 100 ether);
    }

    // ─── OPTIMIZED CONTRACT ───────────────────────────────────────────

    function test_gas_optimized_createAssertion() public {
        vm.prank(user1);
        optimized.createAssertion{value: BOND + MARKET}(CLAIM);
    }

    function test_gas_optimized_disputeAssertion() public {
        vm.prank(user1);
        bytes32 id = optimized.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.prank(user2);
        optimized.disputeAssertion{value: BOND}(id);
    }

    function test_gas_optimized_settleNoDispute() public {
        vm.prank(user1);
        bytes32 id = optimized.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.warp(block.timestamp + LIVENESS + 1);
        optimized.settleAssertion(id);
    }

    function test_gas_optimized_fullFlowDispute() public {
        vm.prank(user1);
        bytes32 id = optimized.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.prank(user2);
        optimized.disputeAssertion{value: BOND}(id);
        mockOO1.resolveAssertion(id, true);
        optimized.settleAssertion(id);
        vm.prank(user1);
        optimized.withdraw(id);
    }

    function test_gas_optimized_withdraw() public {
        vm.prank(user1);
        bytes32 id = optimized.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.warp(block.timestamp + LIVENESS + 1);
        optimized.settleAssertion(id);
        vm.prank(user1);
        optimized.withdraw(id);
    }

    // ─── NAIVE CONTRACT ──────────────────────────────────────────────

    function test_gas_naive_createAssertion() public {
        vm.prank(user1);
        naive.createAssertion{value: BOND + MARKET}(CLAIM);
    }

    function test_gas_naive_disputeAssertion() public {
        vm.prank(user1);
        bytes32 id = naive.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.prank(user2);
        naive.disputeAssertion{value: BOND}(id);
    }

    function test_gas_naive_settleNoDispute() public {
        vm.prank(user1);
        bytes32 id = naive.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.warp(block.timestamp + LIVENESS + 1);
        naive.settleAssertion(id);
    }

    function test_gas_naive_fullFlowDispute() public {
        vm.prank(user1);
        bytes32 id = naive.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.prank(user2);
        naive.disputeAssertion{value: BOND}(id);
        mockOO2.resolveAssertion(id, true);
        naive.settleAssertion(id);
        vm.prank(user1);
        naive.withdraw(id);
    }

    function test_gas_naive_withdraw() public {
        vm.prank(user1);
        bytes32 id = naive.createAssertion{value: BOND + MARKET}(CLAIM);
        vm.warp(block.timestamp + LIVENESS + 1);
        naive.settleAssertion(id);
        vm.prank(user1);
        naive.withdraw(id);
    }
}
