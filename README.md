# UMA Optimistic Oracle V3 — Assertion Market

A minimal, gas-optimized Solidity smart contract that integrates with UMA's Optimistic Oracle V3 (OO v3) on Sepolia. Users send native ETH to assert truths or dispute them. The contract handles ETH/WETH wrapping internally, supports the full dispute lifecycle, and settles funds only after oracle finality.

**Deployed on Sepolia** — verified on Etherscan, full lifecycle tested on-chain with the real UMA OO v3.

---

## Table of Contents

1. [UMA Optimistic Oracle Flow](#1-uma-optimistic-oracle-flow)
2. [Architecture](#2-architecture)
3. [Dispute Mechanics & Bond Economics](#3-dispute-mechanics--bond-economics)
4. [Edge Case Handling](#4-edge-case-handling)
5. [Gas Optimization & Analysis](#5-gas-optimization--analysis)
6. [Sandbox Oracle Environment](#6-sandbox-oracle-environment)
7. [Test Suite](#7-test-suite)
8. [Design Assumptions](#8-design-assumptions)
9. [Deployment & Usage](#9-deployment--usage)
10. [Project Structure](#10-project-structure)

---

## 1. UMA Optimistic Oracle Flow

The contract implements the **optimistic assertion pattern**: a claim is assumed true unless disputed within a configurable liveness window (default: 2 hours).

```
User sends ETH
     |
     v
createAssertion(claim)
     |
     +---> Wrap bond ETH -> WETH
     +---> Approve WETH to OO v3
     +---> oo.assertTruth(claim, ...) ---> OO v3 holds bond
     +---> Store assertion (asserter, bond, market, status=Active)
     +---> Emit AssertionCreated
     |
     |   Liveness Window (e.g., 2 hours)
     |
     +---- No Dispute ----+           +---- Dispute ----+
     |                    |           |                  |
     v                    |           v                  |
 (liveness expires)       |   disputeAssertion(id)       |
     |                    |       |                      |
     v                    |       +---> Wrap ETH -> WETH |
 settleAssertion(id)      |       +---> oo.disputeAssertion()
     |                    |       +---> Status = Disputed
     v                    |       +---> Emit AssertionDisputed
 OO v3 settles:           |           |
   bond WETH -> contract  |       DVM Resolution (or Sandbox manual)
   callback(true)         |           |
     |                    |           v
     v                    |   settleAssertion(id)
 Status: ResolvedTrue     |       |
     |                    |       v
     v                    |   OO v3 settles based on DVM vote:
 withdraw(id)             |     callback(true)  -> asserter wins
   -> ETH to asserter     |     callback(false) -> disputer wins
                          |       |
                          |       v
                          |   withdraw(id) -> ETH to winner
```

**Key OO v3 integration points:**

| OO v3 Function | When Called | What Happens |
|---|---|---|
| `oo.assertTruth()` | `createAssertion()` | Submits claim with WETH bond, liveness, callback recipient. Returns `assertionId`. |
| `oo.disputeAssertion()` | `disputeAssertion()` | Locks both bonds in OO v3. Escalates to DVM for resolution. |
| `oo.settleAssertion()` | `settleAssertion()` | Triggers liveness check (reverts if too early). Returns bond WETH to winner. Fires callback. |
| `assertionResolvedCallback()` | Called BY OO v3 | Our contract receives the resolution result. Updates internal status. |
| `assertionDisputedCallback()` | Called BY OO v3 | Our contract is notified of dispute. Safety net for status update. |

---

## 2. Architecture

### 2.1 Contract Design

**Single contract**: `UMAAssertionMarket.sol` (356 lines). Inherits from:
- `OptimisticOracleV3CallbackRecipientInterface` — required callback interface for OO v3
- `ReentrancyGuard` (OpenZeppelin v5) — protects all ETH-transferring functions

**Proxy/Custodian pattern**: Our contract acts as both `asserter` and `disputer` from OO v3's perspective. This is necessary because OO v3 requires WETH (ERC-20) for bonds, but users send ETH. The contract wraps ETH to WETH, submits to OO v3, and internally tracks which user (asserter or disputer) is entitled to the proceeds.

### 2.2 State Design — Gas-Optimized Struct Packing

```
struct AssertionData {
    Slot 1: [asserter: 20B] [timestamp: 8B] [status: 1B]     = 29 bytes (3 bytes wasted)
    Slot 2: [bondAmount: 16B] [marketAmount: 16B]              = 32 bytes (fully packed)
    Slot 3: [disputer: 20B] [withdrawn: 1B]                    = 21 bytes (11 bytes wasted)
    Slot 4: [bondReturned: 16B]                                 = 16 bytes (16 bytes wasted)
}
Total: 4 storage slots per assertion (vs 8 in an unpacked layout)
```

- `asserter` / `disputer`: Track the two parties.
- `timestamp`: When the assertion was created (for liveness calculation).
- `status`: Enum (`Active`, `Disputed`, `ResolvedTrue`, `ResolvedFalse`) — 1 byte.
- `bondAmount` / `marketAmount`: `uint128` (max ~3.4 x 10^20 ETH — far exceeds total supply).
- `withdrawn`: Prevents double withdrawal.
- `bondReturned`: Tracks the actual WETH returned by OO v3 via a balance snapshot during `settleAssertion()`.

### 2.3 Immutable Variables (Zero SLOAD Cost)

| Variable | Type | Purpose |
|---|---|---|
| `oo` | `OptimisticOracleV3Interface` | OO v3 contract address |
| `weth` | `IWETH9` | WETH9 contract address |
| `defaultIdentifier` | `bytes32` | `ASSERT_TRUTH` — fetched from OO v3 at deploy time |
| `defaultLiveness` | `uint64` | Liveness window in seconds |
| `defaultBond` | `uint256` | Bond amount (0 = use OO v3 minimum) |

All stored in bytecode (not storage), so reads cost 3 gas instead of 2,100 gas (cold SLOAD).

### 2.4 Storage

Only one mapping:
```solidity
mapping(bytes32 => AssertionData) public assertions;
```
No arrays, no counters, no admin state. The `assertionId` comes from OO v3, not from us.

### 2.5 Events

| Event | Indexed Fields | Data |
|---|---|---|
| `AssertionCreated` | `assertionId`, `asserter` | `bondAmount`, `marketAmount`, `claim` |
| `AssertionDisputed` | `assertionId`, `disputer` | `disputeBond` |
| `AssertionResolved` | `assertionId` | `assertedTruthfully` |
| `FundsWithdrawn` | `assertionId`, `recipient` | `amount` |

Claim text is emitted in the event (not stored on-chain) to save storage gas.

### 2.6 Custom Errors

8 custom errors replace `require("string")` — saves ~200 gas per revert:

| Error | When |
|---|---|
| `InsufficientETH()` | `msg.value` < required bond |
| `AssertionNotFound()` | Unknown `assertionId` |
| `AssertionNotActive()` | Assertion not in `Active` status for dispute |
| `AssertionNotResolved()` | Trying to withdraw before resolution |
| `AlreadyWithdrawn()` | Double withdrawal attempt |
| `SelfDispute()` | Asserter trying to dispute their own assertion |
| `OnlyOracle()` | Non-oracle calling callback |
| `NothingToWithdraw()` | Zero payout |
| `TransferFailed()` | ETH transfer reverted |

### 2.7 Function Overview

| Function | Access | Payable | ReentrancyGuard | Description |
|---|---|---|---|---|
| `createAssertion(bytes)` | External | Yes | Yes | Accept ETH (bond + market), wrap to WETH, call `oo.assertTruth()` |
| `disputeAssertion(bytes32)` | External | Yes | Yes | Accept dispute bond in ETH, wrap to WETH, call `oo.disputeAssertion()` |
| `assertionResolvedCallback(bytes32, bool)` | External (OO v3 only) | No | No | Oracle callback — updates resolution status |
| `assertionDisputedCallback(bytes32)` | External (OO v3 only) | No | No | Oracle callback — safety net for dispute status |
| `settleAssertion(bytes32)` | External | No | No | Triggers `oo.settleAssertion()`, snapshots WETH returned |
| `withdraw(bytes32)` | External | No | Yes | Pull-over-push: winner claims ETH after resolution |
| `getEffectiveBond()` | External view | No | No | Returns `max(defaultBond, oo.getMinimumBond(weth))` |
| `getAssertionData(bytes32)` | External view | No | No | Returns full assertion struct |

---

## 3. Dispute Mechanics & Bond Economics

### 3.1 Two-Party Model

An **asserter** stakes ETH on a claim. Any address (except the asserter) can **dispute** by posting an equal bond.

1. **Create**: Asserter sends `bond + marketAmount` ETH. Bond wraps to WETH and goes to OO v3. Market amount stays in our contract.

2. **Dispute**: Disputer sends `bond` ETH within the liveness window. Bond wraps to WETH and goes to OO v3. Both bonds are now locked. The assertion enters the DVM (Data Verification Mechanism) resolution process.

3. **Resolution**: OO v3 calls `assertionResolvedCallback(id, truthful)` after DVM votes:
   - `truthful == true` → Asserter wins
   - `truthful == false` → Disputer wins

4. **Withdrawal**: Winner calls `withdraw(assertionId)` to claim their funds.

### 3.2 Bond Economics (Mirrors UMA Mainnet)

UMA's OO v3 uses a `burnedBondPercentage` of `0.5e18` (50%). On settlement:

| Scenario | Bond Returned to Winner | UMA Store Fee | Market Funds |
|---|---|---|---|
| **No dispute** | 1.0x bond (full refund) | 0 | Asserter gets all |
| **Dispute — asserter wins** | 1.5x bond (own + half of loser's) | 0.5x bond | Asserter gets all |
| **Dispute — disputer wins** | 1.5x bond (own + half of loser's) | 0.5x bond | Disputer gets all |
| **Dispute — loser** | 0 (entire bond lost) | — | Gets nothing |

**Example with 0.1 ETH bond + 1 ETH market:**
- Asserter sends 1.1 ETH (0.1 bond + 1.0 market)
- Disputer sends 0.1 ETH (bond)
- If asserter wins: asserter withdraws 1.0 (market) + 0.15 (1.5x bond) = **1.15 ETH**
- If disputer wins: disputer withdraws 1.0 (market) + 0.15 (1.5x bond) = **1.15 ETH**
- UMA Store retains: 0.05 ETH (half of loser's bond)

### 3.3 Bond Tracking via WETH Snapshot

Bond settlement is handled by UMA — OO v3 sends WETH back to our contract. We track the exact amount returned per assertion using a balance snapshot:

```solidity
uint256 wethBefore = weth.balanceOf(address(this));
oo.settleAssertion(assertionId);
uint256 wethAfter = weth.balanceOf(address(this));
data.bondReturned = uint128(wethAfter - wethBefore);
```

This isolates per-assertion bond returns even when multiple assertions exist concurrently.

### 3.4 Settlement Separation

Per assessment requirement 4.4, settlement is split into two responsibilities:

- **Bond Settlement (UMA's job)**: OO v3 returns WETH to our contract based on the dispute outcome.
- **Market Settlement (Our job)**: We route `marketAmount` ETH to the winner based on the `status`.

The winner's total payout = `marketAmount + bondReturned`.

---

## 4. Edge Case Handling

### 4.1 Last-Second Disputes
UMA's OO v3 enforces liveness checks in `disputeAssertion()` — if called after the `expirationTime`, the transaction reverts on-chain. Our contract does not need additional time checks; OO v3 handles this atomically. No race condition is possible because block timestamps are deterministic within a transaction.

**Tests**: `test_lastSecondDispute_succeedsBeforeExpiry`, `test_lastSecondDispute_revertAtExpiry`

### 4.2 Concurrent Assertions
Each assertion receives a unique `bytes32 assertionId` from OO v3 (derived from `keccak256(nonce, timestamp, asserter)`). Our contract maps `assertionId => AssertionData` independently. Multiple assertions from the same user are tracked separately with their own bonds, market amounts, and resolution statuses.

**Test**: `test_concurrentAssertions_independent` — creates 2 assertions from the same user, disputes one, resolves differently, verifies independent settlement.

### 4.3 Invalid Callbacks
`assertionResolvedCallback` validates three layers:
1. `msg.sender == address(oo)` — rejects non-oracle callers with `OnlyOracle()`.
2. `assertions[assertionId].asserter != address(0)` — rejects unknown IDs with `AssertionNotFound()`.
3. Status check — if already `ResolvedTrue` or `ResolvedFalse`, silently returns (idempotent). Prevents double-execution and status flipping.

**Tests**: `test_assertionResolvedCallback_revert_onlyOracle`, `test_assertionResolvedCallback_revert_unknownId`, `test_callback_idempotent`, `test_callback_idempotent_flippedTruthfulness`

### 4.4 Balance Changes
The contract **never relies on `address(this).balance`** for payout calculations. Each assertion's `marketAmount` is recorded in its struct at creation time, and `bondReturned` is tracked via the WETH snapshot. External ETH sent to the contract (e.g., accidental transfers) does not affect any assertion's payout.

**Test**: `test_balanceChanges_immuneToExternalTransfers` — a stranger sends 5 ETH to the contract; asserter's withdrawal amount is unaffected.

### 4.5 Re-Submission / Double Settlement
- **Status enum** prevents re-settlement: `withdraw()` requires `status == ResolvedTrue || ResolvedFalse` and `withdrawn == false`.
- **Double withdrawal** reverts with `AlreadyWithdrawn()`.
- **Double settle** reverts in OO v3 ("Already settled").
- `assertionResolvedCallback` is idempotent — calling it twice on a resolved assertion silently returns without modifying state.

**Tests**: `test_doubleSettlement_prevented`, `test_withdraw_revert_doubleWithdraw`

---

## 5. Gas Optimization & Analysis

### 5.1 Optimizations Applied

| Optimization | Where | Savings | Rationale |
|---|---|---|---|
| **Struct packing** (4 slots vs 8) | `AssertionData` struct | ~57,144 gas on `createAssertion` | Halves the number of cold SSTOREs (20,000 gas each). |
| **Custom errors** | All revert paths | ~200 gas/revert | 4-byte selector vs ABI-encoding a string. |
| **Immutable variables** | 5 config values | ~2,100 gas/read | Stored in bytecode (CODECOPY: 3 gas) vs storage (SLOAD: 2,100 gas cold). |
| **`unchecked {}` blocks** | 2 safe arithmetic ops | ~40-60 gas/op | `msg.value - bond` (guarded by prior check), `uint128` casts. |
| **Minimal storage** | No claim text stored | Eliminates SSTORE | Claim text emitted as event — indexable off-chain but free on-chain. |
| **`calldata` for claim** | `createAssertion` param | ~200 gas | `bytes calldata` avoids copying to memory. |

### 5.2 Gas Comparison: Optimized vs Naive Baseline

A **naive (unoptimized) baseline** contract (`test/NaiveBaseline.sol`) was created with identical logic but without any of the optimizations above:
- 8 storage slots per assertion (unpacked `uint256` fields)
- `require("string")` instead of custom errors
- No `unchecked` blocks
- Regular `storage` variables instead of `immutable` (costs 2,100 gas SLOAD per read)
- `bytes memory` instead of `bytes calldata`

**Per-function gas comparison (from `forge test --gas-report`):**

| Function | Naive (gas) | Optimized (gas) | Savings | % Saved |
|---|---|---|---|---|
| `createAssertion` | 324,000 | 266,856 | **57,144** | **17.6%** |
| `disputeAssertion` | 155,476 | 134,858 | **20,618** | **13.3%** |
| `settleAssertion` | 111,325 | 100,210 | **11,115** | **10.0%** |
| `withdraw` | 62,569 | 58,511 | **4,058** | **6.5%** |

**Full lifecycle gas (end-to-end tests):**

| Flow | Naive (gas) | Optimized (gas) | Savings | % Saved |
|---|---|---|---|---|
| Create + Dispute + Settle + Withdraw | 625,039 | 542,253 | **82,786** | **13.2%** |
| Create + Settle (no dispute) + Withdraw | 491,393 | 407,026 | **84,367** | **17.2%** |

**Where the savings come from:**
1. **Struct packing** (57k on create): Writing 4 storage slots instead of 8. Each cold SSTORE costs 20,000 gas.
2. **Immutables** (~10.5k across lifecycle): 5 variables read from bytecode instead of storage. `5 x 2,097 = ~10,485` gas saved per call reading all 5.
3. **Custom errors** (~200 per revert): Selector-only encoding vs string encoding.
4. **Unchecked** (~100 total): Skips overflow checks on 2 provably-safe operations.
5. **Calldata** (~200 on create): Avoids memory copy of claim bytes.

### 5.3 Configuration Justification

**Liveness Period: 7200s (2 hours)** — Standard for testnet deployments. Provides adequate time for disputers to react while keeping test cycles short. For mainnet, 4-24 hours would be more appropriate depending on value at risk.

**Bond Size: `max(defaultBond, oo.getMinimumBond(weth))`** — The `_getEffectiveBond()` function ensures the bond is never below OO v3's minimum. On Sepolia, the OO v3 minimum for WETH is 0, so we set an explicit `0.001 ETH` bond to make the economics meaningful. For mainnet, bonds should exceed the final fee to incentivize honest disputes.

### 5.4 Gas Snapshot (per test)

Full gas snapshot generated via `forge snapshot`:

| Test | Gas |
|---|---|
| `test_createAssertion_success` | 266,681 |
| `test_disputeAssertion_success` | 340,874 |
| `test_fullFlow_noDisputeSettleAfterLiveness` | 322,467 |
| `test_fullFlow_disputeAsserterWins` | 402,717 |
| `test_fullFlow_disputeDisputerWins` | 403,054 |
| `test_concurrentAssertions_independent` | 648,762 |
| `test_balanceChanges_immuneToExternalTransfers` | 328,672 |
| `test_bondEconomics_disputed_winnerGets150Percent` | 397,225 |
| `test_bondEconomics_umaStoreFee_remainsInMock` | 398,321 |

---

## 6. Sandbox Oracle Environment

### 6.1 Why a Sandbox?

The live UMA OO v3 on Sepolia works for undisputed assertions (just wait for liveness). But for **disputed assertions**, the DVM (Data Verification Mechanism) requires active voters — which may not exist on Sepolia testnet. The sandbox environment solves this by deploying a `MockOptimisticOracleV3` that allows **manual dispute resolution**.

**The sandbox is used exclusively for testing.** The deliverable deployment uses the real UMA OO v3 at `0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944`.

### 6.2 What Gets Deployed

The `OracleSandbox.s.sol` script deploys three contracts:

1. **WETH9** — Standard Wrapped ETH (test instance).
2. **MockOptimisticOracleV3** — Simulates OO v3 with manual dispute resolution.
3. **UMAAssertionMarket** — Same contract, pointed at the mock OO instead of the live one.

### 6.3 How the Mock Works

`MockOptimisticOracleV3` (`test/mocks/MockOptimisticOracleV3.sol`, 197 lines) implements the full `OptimisticOracleV3Interface` and mirrors mainnet behavior:

**Same as mainnet:**
- `assertTruth()` — accepts bond via `transferFrom`, stores assertion, returns unique ID.
- `disputeAssertion()` — accepts dispute bond, validates liveness, calls `assertionDisputedCallback`.
- `settleAssertion()` — validates liveness/resolution, transfers bonds, calls `assertionResolvedCallback`.
- Bond economics: winner gets 1.5x bond, UMA Store (mock) retains 0.5x bond.

**Sandbox-specific:**
- `resolveAssertion(assertionId, truthful)` — Simulates DVM vote. Sets the resolution result without settling. You must still call `settleAssertion()` afterwards (two-step flow, matching mainnet).

### 6.4 Two-Step Dispute Resolution

The mock uses a two-step flow that matches the real OO v3:

```
Step 1: resolveAssertion(id, true/false)   // Simulates DVM vote
Step 2: settleAssertion(id)                 // Executes bond transfer + callback
```

This ensures our contract's `settleAssertion()` function (with the WETH balance snapshot) works identically against both the mock and the real oracle.

### 6.5 Sandbox Addresses (Sepolia)

| Contract | Address |
|---|---|
| MockOptimisticOracleV3 | `0xB7f6f30D13F36c1d8b6E807C5b8ad0dDCd7773eE` |
| UMAAssertionMarket (Sandbox) | `0xb7124808330784A14fA5272846F35e1203E826D9` |
| WETH9 (Sandbox) | Deployed by sandbox script |

---

## 7. Test Suite

**48 tests total** (38 main + 10 gas comparison), all passing. Uses Foundry's `forge test`.

### 7.1 Test Categories

**Create Assertion (4 tests):**
- `test_createAssertion_success` — verifies all struct fields stored correctly
- `test_createAssertion_emitsEvent` — event emission check
- `test_createAssertion_exactBondNoMarket` — bond-only assertion (zero market)
- `test_createAssertion_revert_insufficientETH` — revert on low ETH

**Dispute (7 tests):**
- `test_disputeAssertion_success` — disputer recorded, status updated
- `test_disputeAssertion_refundsExcess` — excess ETH returned to disputer
- `test_disputeAssertion_emitsEvent` — event emission check
- `test_disputeAssertion_revert_notFound` — unknown assertionId
- `test_disputeAssertion_revert_notActive` — already disputed/resolved
- `test_disputeAssertion_revert_insufficientETH` — bond too low
- `test_disputeAssertion_revert_selfDispute` — asserter cannot dispute own assertion

**Callback Security (3 tests):**
- `test_assertionResolvedCallback_revert_onlyOracle` — non-oracle caller rejected
- `test_assertionResolvedCallback_revert_unknownId` — unknown assertionId rejected
- `test_assertionDisputedCallback_revert_onlyOracle` — non-oracle caller rejected

**Full Lifecycle (3 tests):**
- `test_fullFlow_disputeAsserterWins` — create → dispute → DVM resolves TRUE → settle → asserter withdraws (bond + reward + market)
- `test_fullFlow_disputeDisputerWins` — create → dispute → DVM resolves FALSE → settle → disputer withdraws (bond + reward + market)
- `test_fullFlow_noDisputeSettleAfterLiveness` — create → warp past liveness → settle → asserter withdraws (bond + market)

**Settlement Edge Cases (6 tests):**
- `test_settleAssertion_revert_tooEarly` — cannot settle before liveness
- `test_settleAssertion_revert_notFound` — unknown assertionId
- `test_settleAssertion_revert_disputedButNotResolved` — disputed but DVM hasn't voted
- `test_withdraw_revert_notResolved` — cannot withdraw before resolution
- `test_withdraw_revert_doubleWithdraw` — double withdrawal prevented
- `test_withdraw_revert_notFound` — unknown assertionId

**Edge Cases (5 tests):**
- `test_concurrentAssertions_independent` — two assertions from same user, independent lifecycle
- `test_balanceChanges_immuneToExternalTransfers` — external ETH doesn't affect payouts
- `test_doubleSettlement_prevented` — OO v3 reverts on second settle
- `test_callback_idempotent` — double callback silently ignored
- `test_callback_idempotent_flippedTruthfulness` — cannot flip resolution via replay

**Bond Economics (4 tests):**
- `test_bondEconomics_noDispute_fullBondReturned` — 1x bond returned
- `test_bondEconomics_disputed_winnerGets150Percent` — 1.5x bond returned
- `test_bondEconomics_disputed_loserLosesEntireBond` — 0 bond, no market
- `test_bondEconomics_umaStoreFee_remainsInMock` — 0.5x stays in mock (UMA Store)

**View Functions & Misc (4 tests):**
- `test_getEffectiveBond` — returns correct bond
- `test_getAssertionData_defaultValues` — zero struct for unknown ID
- `test_withdraw_bondOnlyAssertion_returnsBond` — bond-only assertion withdrawable
- `test_withdraw_thirdPartyTrigger_payoutGoesToWinner` — anyone can trigger withdraw, payout goes to winner

**Gas Comparison (10 tests):**
- 5 optimized + 5 naive baseline tests for before/after comparison

---

## 8. Design Assumptions

### 8.1 Proxy/Custodian Pattern
Our contract is both `asserter` and `disputer` from OO v3's perspective. OO v3 always sends bond WETH to `address(this)`. We route funds to the correct user internally based on `data.status`. This is the standard pattern for ETH-to-WETH wrapper contracts (UMA's own reference implementations like `Insurance.sol` use the same approach).

### 8.2 Single Winner Takes All
Market settlement is all-or-nothing — the winner gets 100% of `marketAmount`. No partial payouts or proportional distribution. This matches the assessment's two-party model ("funds released to asserter" or "released to disputer").

### 8.3 `uint128` for Amounts
Bond and market amounts use `uint128` (max ~3.4 x 10^38 wei = ~3.4 x 10^20 ETH). Total ETH supply is ~120M ETH. Overflow is physically impossible. This enables tight struct packing (two `uint128` values in one 32-byte slot).

### 8.4 Anyone Can Trigger Settlement/Withdrawal
`settleAssertion()` and `withdraw()` are public — any address can trigger them. However, the payout always goes to the **rightful winner** (asserter or disputer). A third party triggering `withdraw()` pays the gas but receives nothing. This is by design (pull-over-push pattern).

### 8.5 Self-Dispute Prevention
The asserter cannot dispute their own assertion (`SelfDispute` error). This is economically irrational — the asserter is guaranteed to lose 0.5x bond to the UMA Store regardless of the outcome.

### 8.6 No Escalation Manager
We pass `address(0)` as the escalation manager to `assertTruth()`. Disputes go directly to UMA's DVM. An escalation manager could add intermediate resolution steps but is not required by the assessment.

### 8.7 WETH Unwrap in Withdraw
`withdraw()` unwraps the contract's entire WETH balance (not just `bondReturned`). This is safe because each assertion's payout is calculated from its own `marketAmount + bondReturned`, and the contract always holds enough total ETH/WETH to cover all outstanding payouts.

### 8.8 ResolvedFalse Without Disputer
If an assertion somehow resolves FALSE without a disputer (theoretical edge case), funds go back to the asserter rather than being locked forever. In practice, undisputed assertions always resolve TRUE via OO v3.

---

## 9. Deployment & Usage

### 9.1 Prerequisites
- [Foundry](https://getfoundry.sh/) (v1.4.4+)
- Sepolia ETH (from faucets)
- MetaMask or similar wallet (for frontend)

### 9.2 Build & Test
```bash
forge build
forge test -vvv           # All 48 tests
forge test --gas-report   # Gas breakdown per function
forge snapshot            # Generate .gas-snapshot file
```

### 9.3 Deploy to Sepolia (Live OO v3)
```bash
cp .env.example .env
# Edit .env with your PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY

source .env
forge script script/Deploy.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
```

### 9.4 Deploy Sandbox (Isolated Testing)
```bash
forge script script/OracleSandbox.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
```
The sandbox deploys a `MockOptimisticOracleV3` where disputes can be resolved manually via `resolveAssertion(assertionId, truthful)` — no DVM voting needed. Liveness is set to 120 seconds for fast testing.

### 9.5 Interact via cast
```bash
# Create assertion (0.001 ETH bond + 0.01 ETH market)
cast send $MARKET_ADDRESS "createAssertion(bytes)" \
  $(cast --from-utf8 "ETH was above $2500 on 1 Feb 2026") \
  --value 0.011ether --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Dispute (0.001 ETH bond)
cast send $MARKET_ADDRESS "disputeAssertion(bytes32)" $ASSERTION_ID \
  --value 0.001ether --private-key $DISPUTER_KEY --rpc-url $SEPOLIA_RPC_URL

# Settle (after liveness or dispute resolution)
cast send $MARKET_ADDRESS "settleAssertion(bytes32)" $ASSERTION_ID \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Withdraw
cast send $MARKET_ADDRESS "withdraw(bytes32)" $ASSERTION_ID \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Sandbox: resolve dispute manually
cast send $MOCK_OO "resolveAssertion(bytes32,bool)" $ASSERTION_ID true \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

### 9.6 Frontend
A self-contained single-page frontend is available at `frontend/index.html`. Open directly in a browser with MetaMask on Sepolia. Features:
- Create assertions with custom claim text
- Lookup assertions by ID
- Dispute, settle, and withdraw via MetaMask
- Recent assertions feed with live countdown timers
- Toggle between Live and Sandbox deployments

### 9.7 Key Addresses (Sepolia)

| Contract | Address |
|---|---|
| **UMAAssertionMarket (Live)** | `0x8B3EdFDa4f8fBe460CaB65659a84B18e0a12B58A` |
| **UMAAssertionMarket (Sandbox)** | `0xb7124808330784A14fA5272846F35e1203E826D9` |
| UMA Optimistic Oracle V3 | `0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944` |
| WETH9 (Sepolia) | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` |
| Finder | `0xf4C48eDAd256326086AEfbd1A53e1896815F8f13` |
| MockOptimisticOracleV3 (Sandbox) | `0xB7f6f30D13F36c1d8b6E807C5b8ad0dDCd7773eE` |
| UMA Testnet Oracle UI | https://testnet.oracle.uma.xyz |

---

## 10. Project Structure

```
UMA/
├── src/
│   ├── UMAAssertionMarket.sol          # Main contract (356 lines)
│   └── interfaces/
│       ├── OptimisticOracleV3Interface.sol
│       ├── OptimisticOracleV3CallbackRecipientInterface.sol
│       └── IWETH9.sol
├── test/
│   ├── UMAAssertionMarket.t.sol        # Main test suite (38 tests)
│   ├── GasComparison.t.sol             # Optimized vs naive gas comparison (10 tests)
│   ├── NaiveBaseline.sol               # Unoptimized baseline for gas analysis
│   └── mocks/
│       ├── MockOptimisticOracleV3.sol   # Sandbox oracle (mirrors mainnet economics)
│       └── WETH9.sol                    # Minimal WETH9 for testing
├── script/
│   ├── Deploy.s.sol                     # Live deployment (real OO v3)
│   └── OracleSandbox.s.sol              # Sandbox deployment (mock OO)
├── frontend/
│   └── index.html                       # Single-page frontend (MetaMask + ethers.js v6)
├── foundry.toml                         # Foundry config (Solidity 0.8.22, optimizer 200 runs)
├── remappings.txt                       # @openzeppelin/ import mapping
├── .env.example                         # Environment template
├── .gas-snapshot                         # Foundry gas snapshot
└── README.md                            # This file
```
