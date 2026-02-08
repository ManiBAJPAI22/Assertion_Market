// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {OptimisticOracleV3Interface} from "../src/interfaces/OptimisticOracleV3Interface.sol";
import {
    OptimisticOracleV3CallbackRecipientInterface
} from "../src/interfaces/OptimisticOracleV3CallbackRecipientInterface.sol";
import {IWETH9} from "../src/interfaces/IWETH9.sol";

/// @title UMAAssertionMarketNaive — UNOPTIMIZED baseline for gas comparison
/// @notice Same logic as UMAAssertionMarket but WITHOUT gas optimizations:
///         - No struct packing (each field in its own slot)
///         - No custom errors (uses require strings)
///         - No unchecked blocks
///         - No immutables (uses regular storage variables)
///         - Uses `bytes memory` instead of `bytes calldata`
contract UMAAssertionMarketNaive is OptimisticOracleV3CallbackRecipientInterface, ReentrancyGuard {
    // ── NO custom errors — uses require strings instead ──

    // ── UNPACKED struct: each field gets its own slot ──
    struct AssertionData {
        address asserter; // slot 1 (20 bytes, wastes 12)
        uint256 timestamp; // slot 2 (32 bytes — full uint256 instead of uint64)
        uint256 status; // slot 3 (32 bytes — full uint256 instead of uint8 enum)
        uint256 bondAmount; // slot 4 (32 bytes — full uint256 instead of uint128)
        uint256 marketAmount; // slot 5 (32 bytes — full uint256 instead of uint128)
        address disputer; // slot 6 (20 bytes, wastes 12)
        bool withdrawn; // slot 7 (1 byte, wastes 31)
        uint256 bondReturned; // slot 8 (32 bytes — full uint256 instead of uint128)
    }
    // Total: 8 storage slots (vs 4 in optimized)

    event AssertionCreated(
        bytes32 indexed assertionId, address indexed asserter, uint256 bondAmount, uint256 marketAmount, bytes claim
    );
    event AssertionDisputed(bytes32 indexed assertionId, address indexed disputer, uint256 disputeBond);
    event AssertionResolved(bytes32 indexed assertionId, bool assertedTruthfully);
    event FundsWithdrawn(bytes32 indexed assertionId, address indexed recipient, uint256 amount);

    // ── NO immutables — uses regular storage (costs SLOAD each read) ──
    OptimisticOracleV3Interface public oo;
    IWETH9 public weth;
    bytes32 public defaultIdentifier;
    uint256 public defaultLiveness;
    uint256 public defaultBond;

    mapping(bytes32 => AssertionData) public assertions;

    constructor(address _oo, address _weth, uint64 _defaultLiveness, uint256 _defaultBond) {
        oo = OptimisticOracleV3Interface(_oo);
        weth = IWETH9(_weth);
        defaultIdentifier = oo.defaultIdentifier();
        defaultLiveness = _defaultLiveness;
        defaultBond = _defaultBond;
    }

    // ── Uses `bytes memory` instead of `bytes calldata` ──
    function createAssertion(bytes memory claim) external payable nonReentrant returns (bytes32 assertionId) {
        uint256 bond = _getEffectiveBond();
        // NO custom error — uses require string
        require(msg.value >= bond, "Insufficient ETH sent");

        // NO unchecked — pays for overflow checks
        uint256 bondAmt = bond;
        uint256 marketAmt = msg.value - bond;

        weth.deposit{value: bond}();
        weth.approve(address(oo), bond);

        assertionId = oo.assertTruth(
            claim,
            address(this),
            address(this),
            address(0),
            uint64(defaultLiveness),
            IERC20(address(weth)),
            bond,
            defaultIdentifier,
            bytes32(0)
        );

        // Writes to 8 separate storage slots (vs 4 in optimized)
        AssertionData storage data = assertions[assertionId];
        data.asserter = msg.sender;
        data.timestamp = block.timestamp;
        data.status = 0; // Active
        data.bondAmount = bondAmt;
        data.marketAmount = marketAmt;
        data.disputer = address(0);
        data.withdrawn = false;
        data.bondReturned = 0;

        emit AssertionCreated(assertionId, msg.sender, bondAmt, marketAmt, claim);
    }

    function disputeAssertion(bytes32 assertionId) external payable nonReentrant {
        AssertionData storage data = assertions[assertionId];
        require(data.asserter != address(0), "Assertion not found");
        require(data.status == 0, "Assertion not active");
        require(msg.sender != data.asserter, "Cannot dispute own assertion");

        uint256 bond = _getEffectiveBond();
        require(msg.value >= bond, "Insufficient ETH for dispute bond");

        data.disputer = msg.sender;
        data.status = 1; // Disputed

        weth.deposit{value: bond}();
        weth.approve(address(oo), bond);

        oo.disputeAssertion(assertionId, address(this));

        // NO unchecked
        uint256 excess = msg.value - bond;
        if (excess > 0) {
            (bool ok,) = msg.sender.call{value: excess}("");
            require(ok, "ETH transfer failed");
        }

        emit AssertionDisputed(assertionId, msg.sender, bond);
    }

    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external override {
        require(msg.sender == address(oo), "Only oracle can call");

        AssertionData storage data = assertions[assertionId];
        require(data.asserter != address(0), "Unknown assertion");
        if (data.status == 2 || data.status == 3) {
            return;
        }

        if (assertedTruthfully) {
            data.status = 2; // ResolvedTrue
        } else {
            data.status = 3; // ResolvedFalse
        }

        emit AssertionResolved(assertionId, assertedTruthfully);
    }

    function assertionDisputedCallback(bytes32 assertionId) external override {
        require(msg.sender == address(oo), "Only oracle can call");
        AssertionData storage data = assertions[assertionId];
        if (data.asserter != address(0) && data.status == 0) {
            data.status = 1;
        }
    }

    function settleAssertion(bytes32 assertionId) external {
        AssertionData storage data = assertions[assertionId];
        require(data.asserter != address(0), "Assertion not found");

        uint256 wethBefore = weth.balanceOf(address(this));
        oo.settleAssertion(assertionId);
        uint256 wethAfter = weth.balanceOf(address(this));

        if (wethAfter > wethBefore) {
            data.bondReturned = wethAfter - wethBefore;
        }
    }

    function withdraw(bytes32 assertionId) external nonReentrant {
        AssertionData storage data = assertions[assertionId];
        require(data.asserter != address(0), "Assertion not found");
        require(data.status == 2 || data.status == 3, "Not resolved");
        require(!data.withdrawn, "Already withdrawn");

        address recipient;
        if (data.status == 2) {
            recipient = data.asserter;
        } else {
            recipient = data.disputer != address(0) ? data.disputer : data.asserter;
        }

        // NO unchecked — uses checked addition
        uint256 payout = data.marketAmount + data.bondReturned;
        require(payout > 0, "Nothing to withdraw");

        data.withdrawn = true;

        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) {
            weth.withdraw(wethBalance);
        }

        (bool ok,) = recipient.call{value: payout}("");
        require(ok, "ETH transfer failed");

        emit FundsWithdrawn(assertionId, recipient, payout);
    }

    function getEffectiveBond() external view returns (uint256) {
        return _getEffectiveBond();
    }

    function getAssertionData(bytes32 assertionId) external view returns (AssertionData memory) {
        return assertions[assertionId];
    }

    function _getEffectiveBond() internal view returns (uint256) {
        // Reads from storage (SLOAD) — not immutable
        uint256 minBond = oo.getMinimumBond(address(weth));
        return defaultBond > minBond ? defaultBond : minBond;
    }

    receive() external payable {}
}
