// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.22;

/// @title Optimistic Oracle V3 Callback Recipient Interface
/// @notice Contracts receiving callbacks from OO v3 must implement this interface.
interface OptimisticOracleV3CallbackRecipientInterface {
    /// @notice Called when an assertion is resolved by the Optimistic Oracle V3.
    /// @param assertionId The unique identifier of the assertion.
    /// @param assertedTruthfully Whether the assertion was resolved as true.
    function assertionResolvedCallback(bytes32 assertionId, bool assertedTruthfully) external;

    /// @notice Called when an assertion is disputed.
    /// @param assertionId The unique identifier of the assertion.
    function assertionDisputedCallback(bytes32 assertionId) external;
}
