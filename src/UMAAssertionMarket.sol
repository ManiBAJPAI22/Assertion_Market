// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OptimisticOracleV3Interface} from "./interfaces/OptimisticOracleV3Interface.sol";
import {
    OptimisticOracleV3CallbackRecipientInterface
} from "./interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";
import {IWETH9} from "./interfaces/IWETH9.sol";

/// @title UMAAssertionMarket
/// @notice A minimal, gas-optimized contract for asserting truths via UMA's Optimistic Oracle V3.
///         Users send native ETH to create assertions or dispute them. The contract handles
///         ETH<->WETH wrapping internally. Settlement follows UMA's economic guarantees —
///         funds move only after oracle finality.
/// @dev Two-party model: asserter stakes ETH on a claim, any address can dispute.
///      Implements OptimisticOracleV3CallbackRecipientInterface for oracle callbacks.
///      Bond settlement is handled by UMA (returned via WETH), market settlement by this contract.
contract UMAAssertionMarket is OptimisticOracleV3CallbackRecipientInterface, ReentrancyGuard {
    // ──────────────────────────────────────────────────────────────────────────
    // Custom Errors (gas-efficient vs require strings)
    // ──────────────────────────────────────────────────────────────────────────

    error InsufficientETH();
    error AssertionNotFound();
    error AssertionNotActive();
    error AssertionNotResolved();
    error AlreadyWithdrawn();
    error SelfDispute();
    error OnlyOracle();
    error NothingToWithdraw();
    error TransferFailed();

    // ──────────────────────────────────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Resolution status of an assertion.
    /// @dev uint8 for tight struct packing.
    enum Status {
        Active, // 0 — assertion live, within liveness period
        Disputed, // 1 — disputed, awaiting DVM resolution
        ResolvedTrue, // 2 — oracle confirmed assertion is TRUE
        ResolvedFalse // 3 — oracle confirmed assertion is FALSE
    }

    /// @notice Per-assertion state. Packed into 4 storage slots.
    /// @dev Slot 1: asserter (20) + timestamp (8) + status (1) = 29 bytes
    ///      Slot 2: bondAmount (16) + marketAmount (16) = 32 bytes
    ///      Slot 3: disputer (20) + withdrawn (1) = 21 bytes
    ///      Slot 4: bondReturned (16) = 16 bytes
    struct AssertionData {
        address asserter; // 20 bytes — who created the assertion
        uint64 timestamp; // 8 bytes  — when assertion was created
        Status status; // 1 byte   — current lifecycle status
        uint128 bondAmount; // 16 bytes — ETH bond amount (wrapped to WETH for OO v3)
        uint128 marketAmount; // 16 bytes — ETH market/bet amount
        address disputer; // 20 bytes — who disputed (address(0) if none)
        bool withdrawn; // 1 byte   — whether funds have been withdrawn
        uint128 bondReturned; // 16 bytes — actual WETH returned by OO v3 on settlement
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────────

    event AssertionCreated(
        bytes32 indexed assertionId, address indexed asserter, uint128 bondAmount, uint128 marketAmount, bytes claim
    );

    event AssertionDisputed(bytes32 indexed assertionId, address indexed disputer, uint128 disputeBond);

    event AssertionResolved(bytes32 indexed assertionId, bool assertedTruthfully);

    event FundsWithdrawn(bytes32 indexed assertionId, address indexed recipient, uint256 amount);

    // ──────────────────────────────────────────────────────────────────────────
    // Immutable State (stored in bytecode, not storage — zero SLOAD cost)
    // ──────────────────────────────────────────────────────────────────────────

    OptimisticOracleV3Interface public immutable oo;
    IWETH9 public immutable weth;
    bytes32 public immutable defaultIdentifier;
    uint64 public immutable defaultLiveness;
    uint256 public immutable defaultBond;

    // ──────────────────────────────────────────────────────────────────────────
    // Storage
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Maps OO v3 assertionId => local assertion data.
    mapping(bytes32 => AssertionData) public assertions;

    // ──────────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────────

    /// @param _oo Address of the UMA Optimistic Oracle V3.
    /// @param _weth Address of the WETH9 contract.
    /// @param _defaultLiveness Liveness period in seconds (e.g. 7200 = 2 hours).
    /// @param _defaultBond Bond amount in wei. If 0, uses OO v3 minimum bond for WETH.
    constructor(address _oo, address _weth, uint64 _defaultLiveness, uint256 _defaultBond) {
        oo = OptimisticOracleV3Interface(_oo);
        weth = IWETH9(_weth);
        defaultIdentifier = oo.defaultIdentifier();
        defaultLiveness = _defaultLiveness;
        defaultBond = _defaultBond;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Core: Create Assertion
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Create an assertion by sending ETH. The bond portion is wrapped to WETH
    ///         and submitted to OO v3. The remaining ETH is the market/bet amount.
    /// @param claim Arbitrary claim text (e.g. "ETH price was above $2,500 on 1 Feb 2026").
    /// @return assertionId The unique identifier assigned by OO v3.
    function createAssertion(bytes calldata claim) external payable nonReentrant returns (bytes32 assertionId) {
        uint256 bond = _getEffectiveBond();
        if (msg.value < bond) revert InsufficientETH();

        uint128 bondAmt;
        uint128 marketAmt;
        unchecked {
            // Safe: bond <= msg.value (checked above), and values fit uint128 for practical ETH amounts
            bondAmt = uint128(bond);
            marketAmt = uint128(msg.value - bond);
        }

        // Wrap bond ETH -> WETH and approve OO v3
        weth.deposit{value: bond}();
        weth.approve(address(oo), bond);

        // Submit assertion to OO v3
        assertionId = oo.assertTruth(
            claim,
            address(this), // asserter is this contract (bond payer)
            address(this), // callback recipient
            address(0), // no escalation manager
            defaultLiveness,
            IERC20(address(weth)),
            bond,
            defaultIdentifier,
            bytes32(0) // no domain
        );

        // Store assertion data (CEI: state before external calls already done via WETH)
        assertions[assertionId] = AssertionData({
            asserter: msg.sender,
            timestamp: uint64(block.timestamp),
            status: Status.Active,
            bondAmount: bondAmt,
            marketAmount: marketAmt,
            disputer: address(0),
            withdrawn: false,
            bondReturned: 0
        });

        emit AssertionCreated(assertionId, msg.sender, bondAmt, marketAmt, claim);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Core: Dispute Assertion
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Dispute an active assertion by sending ETH for the dispute bond.
    ///         The bond is wrapped to WETH and forwarded to OO v3.
    /// @param assertionId The assertion to dispute.
    function disputeAssertion(bytes32 assertionId) external payable nonReentrant {
        AssertionData storage data = assertions[assertionId];
        if (data.asserter == address(0)) revert AssertionNotFound();
        if (data.status != Status.Active) revert AssertionNotActive();
        if (msg.sender == data.asserter) revert SelfDispute();

        uint256 bond = _getEffectiveBond();
        if (msg.value < bond) revert InsufficientETH();

        // Record disputer before external calls (CEI)
        data.disputer = msg.sender;
        data.status = Status.Disputed;

        // Wrap dispute bond ETH -> WETH and approve OO v3
        weth.deposit{value: bond}();
        weth.approve(address(oo), bond);

        // Forward dispute to OO v3
        oo.disputeAssertion(assertionId, address(this));

        // Refund excess ETH
        uint256 excess;
        unchecked {
            excess = msg.value - bond; // Safe: bond <= msg.value
        }
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            if (!ok) revert TransferFailed();
        }

        emit AssertionDisputed(assertionId, msg.sender, uint128(bond));
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Core: Oracle Callbacks
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Called by OO v3 when an assertion is resolved.
    /// @dev SECURITY: Only the OO v3 oracle can call this. State is updated before any
    ///      value movement (CEI). Executes exactly once per assertion via status check.
    /// @param assertionId The resolved assertion's ID.
    /// @param assertedTruthfully Whether the assertion was confirmed as true.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        if (msg.sender != address(oo)) revert OnlyOracle();

        AssertionData storage data = assertions[assertionId];
        // Guard: reject unknown assertion IDs and prevent double-execution
        if (data.asserter == address(0)) revert AssertionNotFound();
        if (data.status == Status.ResolvedTrue || data.status == Status.ResolvedFalse) {
            return; // Already resolved — idempotent safety
        }

        // CEI: Update state before any external interaction
        if (assertedTruthfully) {
            data.status = Status.ResolvedTrue;
        } else {
            data.status = Status.ResolvedFalse;
        }

        emit AssertionResolved(assertionId, assertedTruthfully);
    }

    /// @notice Called by OO v3 when an assertion is disputed.
    /// @dev We already track dispute status in disputeAssertion(), so this is a no-op
    ///      for state but we validate the caller for security.
    /// @param assertionId The disputed assertion's ID.
    function assertionDisputedCallback(bytes32 assertionId) external override {
        if (msg.sender != address(oo)) revert OnlyOracle();
        // Status already set to Disputed in disputeAssertion().
        // If for some reason it's not, update it here as a safety net.
        AssertionData storage data = assertions[assertionId];
        if (data.asserter != address(0) && data.status == Status.Active) {
            data.status = Status.Disputed;
        }
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Core: Settlement
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Trigger settlement on OO v3. Snapshots the WETH returned by OO v3
    ///         to track per-assertion bond returns (bond settlement handled by UMA).
    /// @param assertionId The assertion to settle.
    function settleAssertion(bytes32 assertionId) external {
        AssertionData storage data = assertions[assertionId];
        if (data.asserter == address(0)) revert AssertionNotFound();

        // Snapshot WETH balance before OO v3 settlement
        uint256 wethBefore = weth.balanceOf(address(this));

        // OO v3 handles the liveness check internally and reverts if too early.
        // On settlement, OO v3 transfers bond WETH back to this contract and fires callback.
        oo.settleAssertion(assertionId);

        // Track actual WETH returned by OO v3 for this specific assertion
        uint256 wethAfter = weth.balanceOf(address(this));
        if (wethAfter > wethBefore) {
            data.bondReturned = uint128(wethAfter - wethBefore);
        }
    }

    /// @notice Withdraw entitled funds after oracle finality (pull-over-push pattern).
    /// @dev Settlement is split per assessment 4.4:
    ///      - Bond Settlement (Handled by UMA): OO v3 returns WETH to this contract.
    ///        Amount depends on outcome: 1× bond (no dispute) or 1.5× bond (dispute winner
    ///        gets their bond + half loser's; UMA Store keeps the other half).
    ///      - Market Settlement (Handled by Us): market/bet ETH goes to the winner.
    ///      Winner = asserter if TRUE, disputer if FALSE.
    /// @param assertionId The resolved assertion to withdraw from.
    function withdraw(bytes32 assertionId) external nonReentrant {
        AssertionData storage data = assertions[assertionId];
        if (data.asserter == address(0)) revert AssertionNotFound();
        if (data.status != Status.ResolvedTrue && data.status != Status.ResolvedFalse) {
            revert AssertionNotResolved();
        }
        if (data.withdrawn) revert AlreadyWithdrawn();

        address recipient;

        if (data.status == Status.ResolvedTrue) {
            // Asserter wins: gets market funds + bond returned by OO v3
            recipient = data.asserter;
        } else {
            // Disputer wins: gets market funds + bond returned by OO v3
            // If no disputer (assertion resolved false without dispute — edge case),
            // funds go back to asserter
            recipient = data.disputer != address(0) ? data.disputer : data.asserter;
        }

        // Payout = market settlement (our job) + bond settlement (UMA's return)
        uint256 payout = uint256(data.marketAmount) + uint256(data.bondReturned);

        if (payout == 0) revert NothingToWithdraw();

        // CEI: mark withdrawn before transfer
        data.withdrawn = true;

        // Unwrap any WETH bond returned by OO v3 to this contract
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            weth.withdraw(wethBalance);
        }

        // Transfer ETH to recipient
        (bool ok,) = recipient.call{value: payout}("");
        if (!ok) revert TransferFailed();

        emit FundsWithdrawn(assertionId, recipient, payout);
    }

    // ──────────────────────────────────────────────────────────────────────────
    // View Functions
    // ──────────────────────────────────────────────────────────────────────────

    /// @notice Get the effective bond amount (configured or OO v3 minimum).
    function getEffectiveBond() external view returns (uint256) {
        return _getEffectiveBond();
    }

    /// @notice Get the full assertion data for a given assertionId.
    function getAssertionData(bytes32 assertionId) external view returns (AssertionData memory) {
        return assertions[assertionId];
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Internal
    // ──────────────────────────────────────────────────────────────────────────

    /// @dev Returns the larger of defaultBond or OO v3 minimum bond for WETH.
    function _getEffectiveBond() internal view returns (uint256) {
        uint256 minBond = oo.getMinimumBond(address(weth));
        return defaultBond > minBond ? defaultBond : minBond;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Receive ETH (required for WETH.withdraw() and refunds)
    // ──────────────────────────────────────────────────────────────────────────

    receive() external payable {}
}
