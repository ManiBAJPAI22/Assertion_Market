// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";
import {UMAAssertionMarket} from "../src/UMAAssertionMarket.sol";
import {MockOptimisticOracleV3} from "./mocks/MockOptimisticOracleV3.sol";
import {WETH9} from "./mocks/WETH9.sol";

/// @title UMAAssertionMarketTest
/// @notice Comprehensive test suite using sandbox oracle (MockOptimisticOracleV3).
///         Mock mirrors mainnet OO v3 bond economics: winner gets 1.5× bond in disputes.
contract UMAAssertionMarketTest is Test {
    UMAAssertionMarket public market;
    MockOptimisticOracleV3 public mockOO;
    WETH9 public weth;

    address public asserter = makeAddr("asserter");
    address public disputer = makeAddr("disputer");
    address public stranger = makeAddr("stranger");

    uint64  constant LIVENESS = 7200;    // 2 hours
    uint256 constant BOND = 0.1 ether;
    uint256 constant BOND_REWARD = BOND / 2; // Half of loser's bond (UMA mainnet economics)
    uint256 constant MARKET_AMOUNT = 1 ether;
    bytes   constant CLAIM = "ETH price was above $2,500 on 1 Feb 2026 (UTC)";

    function setUp() public {
        // Deploy sandbox oracle environment
        weth = new WETH9();
        mockOO = new MockOptimisticOracleV3(BOND);
        market = new UMAAssertionMarket(address(mockOO), address(weth), LIVENESS, BOND);

        // Fund test accounts
        vm.deal(asserter, 100 ether);
        vm.deal(disputer, 100 ether);
        vm.deal(stranger, 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    function _createAssertion() internal returns (bytes32 assertionId) {
        vm.prank(asserter);
        assertionId = market.createAssertion{value: BOND + MARKET_AMOUNT}(CLAIM);
    }

    function _createAndDispute() internal returns (bytes32 assertionId) {
        assertionId = _createAssertion();
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(assertionId);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CREATE ASSERTION TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_createAssertion_success() public {
        vm.prank(asserter);
        bytes32 id = market.createAssertion{value: BOND + MARKET_AMOUNT}(CLAIM);

        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(data.asserter, asserter);
        assertEq(uint8(data.status), uint8(UMAAssertionMarket.Status.Active));
        assertEq(data.bondAmount, uint128(BOND));
        assertEq(data.marketAmount, uint128(MARKET_AMOUNT));
        assertEq(data.disputer, address(0));
        assertFalse(data.withdrawn);
        assertEq(data.bondReturned, 0);
    }

    function test_createAssertion_emitsEvent() public {
        vm.expectEmit(false, true, false, true);
        emit UMAAssertionMarket.AssertionCreated(
            bytes32(0), // we don't know the ID yet
            asserter,
            uint128(BOND),
            uint128(MARKET_AMOUNT),
            CLAIM
        );
        vm.prank(asserter);
        market.createAssertion{value: BOND + MARKET_AMOUNT}(CLAIM);
    }

    function test_createAssertion_exactBondNoMarket() public {
        vm.prank(asserter);
        bytes32 id = market.createAssertion{value: BOND}(CLAIM);

        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(data.bondAmount, uint128(BOND));
        assertEq(data.marketAmount, 0);
    }

    function test_createAssertion_revert_insufficientETH() public {
        vm.prank(asserter);
        vm.expectRevert(UMAAssertionMarket.InsufficientETH.selector);
        market.createAssertion{value: BOND - 1}(CLAIM);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISPUTE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_disputeAssertion_success() public {
        bytes32 id = _createAssertion();

        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id);

        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(data.disputer, disputer);
        assertEq(uint8(data.status), uint8(UMAAssertionMarket.Status.Disputed));
    }

    function test_disputeAssertion_refundsExcess() public {
        bytes32 id = _createAssertion();

        uint256 balBefore = disputer.balance;
        vm.prank(disputer);
        market.disputeAssertion{value: BOND + 0.5 ether}(id);

        // Disputer should get 0.5 ether refund
        assertEq(disputer.balance, balBefore - BOND);
    }

    function test_disputeAssertion_emitsEvent() public {
        bytes32 id = _createAssertion();

        vm.expectEmit(true, true, false, true);
        emit UMAAssertionMarket.AssertionDisputed(id, disputer, uint128(BOND));
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id);
    }

    function test_disputeAssertion_revert_notFound() public {
        vm.prank(disputer);
        vm.expectRevert(UMAAssertionMarket.AssertionNotFound.selector);
        market.disputeAssertion{value: BOND}(bytes32(uint256(999)));
    }

    function test_disputeAssertion_revert_notActive() public {
        bytes32 id = _createAndDispute();

        vm.prank(stranger);
        vm.expectRevert(UMAAssertionMarket.AssertionNotActive.selector);
        market.disputeAssertion{value: BOND}(id);
    }

    function test_disputeAssertion_revert_insufficientETH() public {
        bytes32 id = _createAssertion();

        vm.prank(disputer);
        vm.expectRevert(UMAAssertionMarket.InsufficientETH.selector);
        market.disputeAssertion{value: BOND - 1}(id);
    }

    function test_disputeAssertion_revert_selfDispute() public {
        bytes32 id = _createAssertion();

        // Asserter tries to dispute their own assertion
        vm.prank(asserter);
        vm.expectRevert(UMAAssertionMarket.SelfDispute.selector);
        market.disputeAssertion{value: BOND}(id);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CALLBACK SECURITY TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_assertionResolvedCallback_revert_onlyOracle() public {
        bytes32 id = _createAssertion();

        vm.prank(stranger);
        vm.expectRevert(UMAAssertionMarket.OnlyOracle.selector);
        market.assertionResolvedCallback(id, true);
    }

    function test_assertionResolvedCallback_revert_unknownId() public {
        vm.prank(address(mockOO));
        vm.expectRevert(UMAAssertionMarket.AssertionNotFound.selector);
        market.assertionResolvedCallback(bytes32(uint256(999)), true);
    }

    function test_assertionDisputedCallback_revert_onlyOracle() public {
        bytes32 id = _createAssertion();

        vm.prank(stranger);
        vm.expectRevert(UMAAssertionMarket.OnlyOracle.selector);
        market.assertionDisputedCallback(id);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // FULL DISPUTE + RESOLUTION FLOW (Two-step: resolve → settle)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_fullFlow_disputeAsserterWins() public {
        // 1. Create assertion
        bytes32 id = _createAssertion();

        // 2. Dispute
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id);

        // 3. DVM resolves: asserter wins (truthful)
        mockOO.resolveAssertion(id, true);

        // 4. Settle (triggers bond return + callback)
        market.settleAssertion(id);

        // 5. Verify status and bondReturned
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(uint8(data.status), uint8(UMAAssertionMarket.Status.ResolvedTrue));
        assertEq(data.bondReturned, uint128(BOND + BOND_REWARD)); // 1.5× bond

        // 6. Asserter withdraws: market + bond + reward
        uint256 balBefore = asserter.balance;
        vm.prank(asserter);
        market.withdraw(id);

        assertEq(asserter.balance, balBefore + MARKET_AMOUNT + BOND + BOND_REWARD);
    }

    function test_fullFlow_disputeDisputerWins() public {
        // 1. Create assertion
        bytes32 id = _createAssertion();

        // 2. Dispute
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id);

        // 3. DVM resolves: disputer wins (not truthful)
        mockOO.resolveAssertion(id, false);

        // 4. Settle (triggers bond return + callback)
        market.settleAssertion(id);

        // 5. Verify status and bondReturned
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(uint8(data.status), uint8(UMAAssertionMarket.Status.ResolvedFalse));
        assertEq(data.bondReturned, uint128(BOND + BOND_REWARD)); // 1.5× bond

        // 6. Disputer withdraws: market + bond + reward
        uint256 balBefore = disputer.balance;
        vm.prank(disputer);
        market.withdraw(id);

        assertEq(disputer.balance, balBefore + MARKET_AMOUNT + BOND + BOND_REWARD);
    }

    function test_fullFlow_noDisputeSettleAfterLiveness() public {
        // 1. Create assertion
        bytes32 id = _createAssertion();

        // 2. Warp past liveness
        vm.warp(block.timestamp + LIVENESS + 1);

        // 3. Settle (triggers callback from mock OO — no dispute, full bond back)
        market.settleAssertion(id);

        // 4. Verify resolved as true (undisputed) with full bond returned
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(uint8(data.status), uint8(UMAAssertionMarket.Status.ResolvedTrue));
        assertEq(data.bondReturned, uint128(BOND)); // 1× bond (no dispute)

        // 5. Asserter withdraws: market + full bond
        uint256 balBefore = asserter.balance;
        vm.prank(asserter);
        market.withdraw(id);

        assertEq(asserter.balance, balBefore + MARKET_AMOUNT + BOND);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // SETTLEMENT EDGE CASES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_settleAssertion_revert_tooEarly() public {
        bytes32 id = _createAssertion();

        // Don't warp, try to settle immediately
        vm.expectRevert("Liveness not expired");
        market.settleAssertion(id);
    }

    function test_settleAssertion_revert_notFound() public {
        vm.expectRevert(UMAAssertionMarket.AssertionNotFound.selector);
        market.settleAssertion(bytes32(uint256(999)));
    }

    function test_settleAssertion_revert_disputedButNotResolved() public {
        bytes32 id = _createAndDispute();

        // Try to settle without DVM resolution
        vm.expectRevert("Not yet resolved by oracle");
        market.settleAssertion(id);
    }

    function test_withdraw_revert_notResolved() public {
        bytes32 id = _createAssertion();

        vm.prank(asserter);
        vm.expectRevert(UMAAssertionMarket.AssertionNotResolved.selector);
        market.withdraw(id);
    }

    function test_withdraw_revert_doubleWithdraw() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        vm.prank(asserter);
        market.withdraw(id);

        // Second withdraw should revert
        vm.prank(asserter);
        vm.expectRevert(UMAAssertionMarket.AlreadyWithdrawn.selector);
        market.withdraw(id);
    }

    function test_withdraw_revert_notFound() public {
        vm.expectRevert(UMAAssertionMarket.AssertionNotFound.selector);
        market.withdraw(bytes32(uint256(999)));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: CONCURRENT ASSERTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_concurrentAssertions_independent() public {
        // Same asserter creates two assertions simultaneously
        vm.startPrank(asserter);
        bytes32 id1 = market.createAssertion{value: BOND + MARKET_AMOUNT}("Claim A");
        bytes32 id2 = market.createAssertion{value: BOND + MARKET_AMOUNT}("Claim B");
        vm.stopPrank();

        // IDs are different
        assertTrue(id1 != id2);

        // Both are active
        assertEq(uint8(market.getAssertionData(id1).status), uint8(UMAAssertionMarket.Status.Active));
        assertEq(uint8(market.getAssertionData(id2).status), uint8(UMAAssertionMarket.Status.Active));

        // Dispute only id1
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id1);

        // id1 is disputed, id2 is still active
        assertEq(uint8(market.getAssertionData(id1).status), uint8(UMAAssertionMarket.Status.Disputed));
        assertEq(uint8(market.getAssertionData(id2).status), uint8(UMAAssertionMarket.Status.Active));

        // Resolve id1 as false (disputer wins)
        mockOO.resolveAssertion(id1, false);

        // Settle both (id2 needs liveness to pass first)
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id1);
        market.settleAssertion(id2);

        // id1 is ResolvedFalse, id2 is ResolvedTrue
        assertEq(uint8(market.getAssertionData(id1).status), uint8(UMAAssertionMarket.Status.ResolvedFalse));
        assertEq(uint8(market.getAssertionData(id2).status), uint8(UMAAssertionMarket.Status.ResolvedTrue));

        // Verify per-assertion bondReturned tracking
        assertEq(market.getAssertionData(id1).bondReturned, uint128(BOND + BOND_REWARD)); // disputed: 1.5×
        assertEq(market.getAssertionData(id2).bondReturned, uint128(BOND)); // undisputed: 1×
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: BALANCE CHANGES
    // ═══════════════════════════════════════════════════════════════════════════

    function test_balanceChanges_immuneToExternalTransfers() public {
        bytes32 id = _createAssertion();

        // Some stranger sends ETH to the contract (unrelated balance change)
        vm.prank(stranger);
        (bool ok,) = address(market).call{value: 5 ether}("");
        assertTrue(ok);

        // Warp and settle
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // Asserter only gets their market amount + bond, not the extra 5 ETH
        uint256 balBefore = asserter.balance;
        vm.prank(asserter);
        market.withdraw(id);

        assertEq(asserter.balance, balBefore + MARKET_AMOUNT + BOND);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: RE-SUBMISSION / DOUBLE SETTLEMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_doubleSettlement_prevented() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);

        // First settle succeeds
        market.settleAssertion(id);

        // Second settle reverts in mock OO ("Already settled")
        vm.expectRevert("Already settled");
        market.settleAssertion(id);
    }

    function test_callback_idempotent() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // Manually call callback again (simulating a bug)
        vm.prank(address(mockOO));
        market.assertionResolvedCallback(id, true);
        // Should silently return without error (idempotent)

        // Status is still ResolvedTrue
        assertEq(uint8(market.getAssertionData(id).status), uint8(UMAAssertionMarket.Status.ResolvedTrue));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VIEW FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_getEffectiveBond() public view {
        assertEq(market.getEffectiveBond(), BOND);
    }

    function test_getAssertionData_defaultValues() public view {
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(bytes32(0));
        assertEq(data.asserter, address(0));
        assertEq(data.bondAmount, 0);
        assertEq(data.marketAmount, 0);
        assertEq(data.bondReturned, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // WITHDRAW WITH NO MARKET AMOUNT (bond-only assertion — bond still returned)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw_bondOnlyAssertion_returnsBond() public {
        // Create assertion with only bond, no market amount
        vm.prank(asserter);
        bytes32 id = market.createAssertion{value: BOND}(CLAIM);

        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // Asserter should get their bond back even with zero market
        uint256 balBefore = asserter.balance;
        vm.prank(asserter);
        market.withdraw(id);

        assertEq(asserter.balance, balBefore + BOND);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: LAST-SECOND DISPUTES (boundary test)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_lastSecondDispute_succeedsBeforeExpiry() public {
        bytes32 id = _createAssertion();

        // Warp to 1 second before liveness expires
        vm.warp(block.timestamp + LIVENESS - 1);

        // Dispute should succeed (block.timestamp < expirationTime)
        vm.prank(disputer);
        market.disputeAssertion{value: BOND}(id);

        assertEq(uint8(market.getAssertionData(id).status), uint8(UMAAssertionMarket.Status.Disputed));
    }

    function test_lastSecondDispute_revertAtExpiry() public {
        bytes32 id = _createAssertion();

        // Warp to exactly when liveness expires
        vm.warp(block.timestamp + LIVENESS);

        // Dispute should fail (block.timestamp >= expirationTime)
        vm.prank(disputer);
        vm.expectRevert("Liveness expired");
        market.disputeAssertion{value: BOND}(id);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: THIRD PARTY CAN TRIGGER WITHDRAW (payout goes to winner)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_withdraw_thirdPartyTrigger_payoutGoesToWinner() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // Stranger calls withdraw, but payout goes to asserter (winner)
        uint256 asserterBalBefore = asserter.balance;
        uint256 strangerBalBefore = stranger.balance;

        vm.prank(stranger);
        market.withdraw(id);

        // Asserter received market funds + bond
        assertEq(asserter.balance, asserterBalBefore + MARKET_AMOUNT + BOND);
        // Stranger balance unchanged
        assertEq(stranger.balance, strangerBalBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASE: CALLBACK IDEMPOTENT WITH FLIPPED TRUTHFULNESS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_callback_idempotent_flippedTruthfulness() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // Status is ResolvedTrue
        assertEq(uint8(market.getAssertionData(id).status), uint8(UMAAssertionMarket.Status.ResolvedTrue));

        // Manually call callback with FALSE (simulating malicious/buggy oracle replay)
        vm.prank(address(mockOO));
        market.assertionResolvedCallback(id, false);

        // Status must remain ResolvedTrue — cannot be flipped
        assertEq(uint8(market.getAssertionData(id).status), uint8(UMAAssertionMarket.Status.ResolvedTrue));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BOND ECONOMICS: Verify UMA mainnet bond split
    // ═══════════════════════════════════════════════════════════════════════════

    function test_bondEconomics_noDispute_fullBondReturned() public {
        bytes32 id = _createAssertion();
        vm.warp(block.timestamp + LIVENESS + 1);
        market.settleAssertion(id);

        // No dispute: full bond returned
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(data.bondReturned, uint128(BOND));
    }

    function test_bondEconomics_disputed_winnerGets150Percent() public {
        bytes32 id = _createAndDispute();
        mockOO.resolveAssertion(id, true);
        market.settleAssertion(id);

        // Disputed, asserter wins: 1.5× bond (their bond + half loser's)
        UMAAssertionMarket.AssertionData memory data = market.getAssertionData(id);
        assertEq(data.bondReturned, uint128(BOND + BOND_REWARD));
    }

    function test_bondEconomics_disputed_loserLosesEntireBond() public {
        // Create assertion, dispute, disputer wins
        bytes32 id = _createAndDispute();
        mockOO.resolveAssertion(id, false);
        market.settleAssertion(id);

        // Disputer wins and withdraws
        uint256 disputerBalBefore = disputer.balance;
        vm.prank(disputer);
        market.withdraw(id);

        // Disputer gets: market + 1.5× bond
        assertEq(disputer.balance, disputerBalBefore + MARKET_AMOUNT + BOND + BOND_REWARD);

        // Asserter gets nothing (their bond was slashed, market went to disputer)
        // Verify asserter can't withdraw again
        vm.prank(asserter);
        vm.expectRevert(UMAAssertionMarket.AlreadyWithdrawn.selector);
        market.withdraw(id);
    }

    function test_bondEconomics_umaStoreFee_remainsInMock() public {
        bytes32 id = _createAndDispute();
        mockOO.resolveAssertion(id, true);

        // Track WETH in mock before settlement (holds both bonds = 2× BOND)
        uint256 mockWethBefore = weth.balanceOf(address(mockOO));
        assertEq(mockWethBefore, 2 * BOND);

        market.settleAssertion(id);

        // Mock retains 0.5× bond (UMA Store fee), returned 1.5× to market contract
        uint256 mockWethAfter = weth.balanceOf(address(mockOO));
        assertEq(mockWethAfter, BOND_REWARD); // 0.5× bond stays in mock
    }
}
