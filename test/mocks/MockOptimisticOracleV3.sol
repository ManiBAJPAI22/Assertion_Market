// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptimisticOracleV3Interface} from "../../src/interfaces/OptimisticOracleV3Interface.sol";
import {OptimisticOracleV3CallbackRecipientInterface} from "../../src/interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";

/// @title MockOptimisticOracleV3
/// @notice Simulates UMA's OO v3 for local Foundry testing (sandbox oracle pattern).
///         Mirrors mainnet bond settlement: winner gets 1.5× bond (their bond + half loser's),
///         UMA Store (simulated) retains 0.5× bond.
///         Uses two-step dispute resolution: resolveAssertion() sets the DVM result,
///         then settleAssertion() executes the settlement (matching real OO v3 flow).
contract MockOptimisticOracleV3 is OptimisticOracleV3Interface {
    uint256 public minimumBond;
    bytes32 public constant DEFAULT_IDENTIFIER = bytes32("ASSERT_TRUTH");
    uint64  public constant DEFAULT_LIVENESS = 7200;

    uint256 private _nextId;

    struct StoredAssertion {
        address asserter;
        address callbackRecipient;
        address disputer;
        IERC20 currency;
        uint256 bond;
        uint64 assertionTime;
        uint64 expirationTime;
        bool settled;
        bool disputed;
        bool resolved;              // DVM has voted (set by resolveAssertion)
        bool settlementResolution;  // DVM result (true = asserter wins)
    }

    mapping(bytes32 => StoredAssertion) public storedAssertions;

    constructor(uint256 _minimumBond) {
        minimumBond = _minimumBond;
    }

    // ── OO v3 Interface Implementations ──────────────────────────────────────

    function defaultIdentifier() external pure override returns (bytes32) {
        return DEFAULT_IDENTIFIER;
    }

    function getMinimumBond(address) external view override returns (uint256) {
        return minimumBond;
    }

    function assertTruth(
        bytes memory,
        address asserter,
        address callbackRecipient,
        address,
        uint64 liveness,
        IERC20 currency,
        uint256 bond,
        bytes32,
        bytes32
    ) external override returns (bytes32 assertionId) {
        require(bond >= minimumBond, "Bond too low");

        // Transfer bond from caller
        currency.transferFrom(msg.sender, address(this), bond);

        assertionId = keccak256(abi.encode(_nextId++, block.timestamp, asserter));

        storedAssertions[assertionId] = StoredAssertion({
            asserter: asserter,
            callbackRecipient: callbackRecipient,
            disputer: address(0),
            currency: currency,
            bond: bond,
            assertionTime: uint64(block.timestamp),
            expirationTime: uint64(block.timestamp) + liveness,
            settled: false,
            disputed: false,
            resolved: false,
            settlementResolution: false
        });

        return assertionId;
    }

    function assertTruthWithDefaults(bytes memory, address) external pure override returns (bytes32) {
        revert("Use assertTruth");
    }

    function disputeAssertion(bytes32 assertionId, address disputer) external override {
        StoredAssertion storage a = storedAssertions[assertionId];
        require(a.asserter != address(0), "Assertion not found");
        require(!a.settled, "Already settled");
        require(!a.disputed, "Already disputed");
        require(block.timestamp < a.expirationTime, "Liveness expired");

        // Transfer dispute bond from caller
        a.currency.transferFrom(msg.sender, address(this), a.bond);

        a.disputed = true;
        a.disputer = disputer;

        // Notify callback recipient
        if (a.callbackRecipient != address(0)) {
            OptimisticOracleV3CallbackRecipientInterface(a.callbackRecipient)
                .assertionDisputedCallback(assertionId);
        }
    }

    function settleAssertion(bytes32 assertionId) external override {
        StoredAssertion storage a = storedAssertions[assertionId];
        require(a.asserter != address(0), "Assertion not found");
        require(!a.settled, "Already settled");

        if (a.disputed) {
            // Disputed: DVM must have resolved first
            require(a.resolved, "Not yet resolved by oracle");
        } else {
            // Undisputed: must be past liveness
            require(block.timestamp >= a.expirationTime, "Liveness not expired");
            a.settlementResolution = true; // Undisputed = truthful
        }

        a.settled = true;

        // ── Bond Settlement (mirrors mainnet OO v3 economics) ────────────
        if (!a.disputed) {
            // No dispute: return full bond to asserter
            a.currency.transfer(a.asserter, a.bond);
        } else if (a.settlementResolution) {
            // Disputed, asserter wins: asserter gets bond + half of disputer's bond
            // UMA Store (mock) retains the other half (0.5× bond)
            a.currency.transfer(a.asserter, a.bond + a.bond / 2);
        } else {
            // Disputed, disputer wins: disputer gets bond + half of asserter's bond
            // UMA Store (mock) retains the other half (0.5× bond)
            if (a.disputer != address(0)) {
                a.currency.transfer(a.disputer, a.bond + a.bond / 2);
            }
        }

        // Notify callback recipient
        if (a.callbackRecipient != address(0)) {
            OptimisticOracleV3CallbackRecipientInterface(a.callbackRecipient)
                .assertionResolvedCallback(assertionId, a.settlementResolution);
        }
    }

    function settleAndGetAssertionResult(bytes32 assertionId) external override returns (bool) {
        this.settleAssertion(assertionId);
        return storedAssertions[assertionId].settlementResolution;
    }

    function getAssertionResult(bytes32 assertionId) external view override returns (bool) {
        require(storedAssertions[assertionId].settled, "Not settled");
        return storedAssertions[assertionId].settlementResolution;
    }

    function getAssertion(bytes32 assertionId) external view override returns (Assertion memory) {
        StoredAssertion storage a = storedAssertions[assertionId];
        return Assertion({
            escalationManagerSettings: EscalationManagerSettings(false, false, false, address(0), address(0)),
            asserter: a.asserter,
            assertionTime: a.assertionTime,
            settled: a.settled,
            currency: a.currency,
            expirationTime: a.expirationTime,
            settlementResolution: a.settlementResolution,
            domainId: bytes32(0),
            identifier: DEFAULT_IDENTIFIER,
            bond: a.bond,
            callbackRecipient: a.callbackRecipient,
            disputer: a.disputer
        });
    }

    function syncUmaParams(bytes32, address) external override {}

    // ── Sandbox-specific: Oracle Resolution ──────────────────────────────────

    /// @notice Simulate DVM vote result (sandbox only). Sets the resolution but does NOT settle.
    ///         Call settleAssertion() afterwards to execute settlement (matching real OO v3 flow).
    /// @param assertionId The disputed assertion.
    /// @param truthful True = asserter wins, False = disputer wins.
    function resolveAssertion(bytes32 assertionId, bool truthful) external {
        StoredAssertion storage a = storedAssertions[assertionId];
        require(a.asserter != address(0), "Assertion not found");
        require(a.disputed, "Not disputed");
        require(!a.settled, "Already settled");
        require(!a.resolved, "Already resolved");

        a.resolved = true;
        a.settlementResolution = truthful;
        // Settlement happens when settleAssertion() is called (two-step flow)
    }
}
