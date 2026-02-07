# UMA Optimistic Oracle V3 — Assertion Market

A minimal, gas-optimized Solidity smart contract that integrates with UMA's Optimistic Oracle V3 (OO v3). Users send native ETH to assert truths or dispute them. The contract handles ETH/WETH wrapping internally, supports the full dispute lifecycle, and settles funds only after oracle finality.

## 1. UMA Optimistic Oracle Flow (As Implemented)

The contract implements the **optimistic assertion pattern**: a claim is assumed true unless disputed within a liveness window.

```
User (ETH) --> createAssertion() --> [Wrap ETH->WETH] --> OO v3.assertTruth()
                                                              |
                                           Liveness Window (default 2h)
                                                              |
                            +---- No Dispute -----------------+
                            |                                 |
                            v                                 v
                   settleAssertion()              disputeAssertion()
                   (after liveness)               [Wrap ETH->WETH] --> OO v3.disputeAssertion()
                            |                                 |
                            v                                 v
                  OO v3 calls back:                   DVM Resolution
            assertionResolvedCallback(true)           (Sandbox: manual)
                            |                                 |
                            v                                 v
                    Status: ResolvedTrue        assertionResolvedCallback(true/false)
                            |                                 |
                            v                                 v
                   withdraw() -> ETH to asserter   withdraw() -> ETH to winner
```

**Key integration points:**
- `oo.assertTruth()` -- submits claim with bond (WETH), liveness, and callback recipient
- `oo.disputeAssertion()` -- disputes within liveness, locks both bonds
- `assertionResolvedCallback()` -- called by OO v3 after finality; updates internal status
- `oo.settleAssertion()` -- triggers resolution for undisputed assertions past liveness

## 2. Architecture

### Contract: `UMAAssertionMarket.sol`

**State Design -- Gas-Optimized Struct Packing (3 slots):**

```
Slot 1: [asserter: 20B] [timestamp: 8B] [status: 1B]     = 29 bytes
Slot 2: [bondAmount: 16B] [marketAmount: 16B]              = 32 bytes
Slot 3: [disputer: 20B] [withdrawn: 1B]                    = 21 bytes
```

**Immutables (zero SLOAD cost):** `oo`, `weth`, `defaultIdentifier`, `defaultLiveness`, `defaultBond`

**Core functions:**

| Function | Description |
|---|---|
| `createAssertion(bytes claim)` | Accept ETH (bond + market), wrap to WETH, call `oo.assertTruth()` |
| `disputeAssertion(bytes32 id)` | Accept dispute bond in ETH, wrap to WETH, call `oo.disputeAssertion()` |
| `assertionResolvedCallback()` | Oracle-only callback; updates resolution status (CEI pattern) |
| `assertionDisputedCallback()` | Oracle-only callback; safety net for dispute status |
| `settleAssertion(bytes32 id)` | Triggers `oo.settleAssertion()` (OO v3 handles liveness check) |
| `withdraw(bytes32 id)` | Pull-over-push: winner claims market funds after resolution |

## 3. Dispute Mechanics

**Two-party model:** An asserter stakes ETH on a claim. Any address can dispute by posting an equal bond.

1. **Asserter** calls `createAssertion{value: bond + marketAmount}(claim)`. Bond is wrapped to WETH and forwarded to OO v3. Market amount stays in the contract.

2. **Disputer** calls `disputeAssertion{value: bond}(assertionId)` within the liveness window. Bond is wrapped to WETH and forwarded to OO v3. The assertion enters the DVM resolution process.

3. **Resolution** -- OO v3 calls `assertionResolvedCallback(id, truthful)`:
   - `truthful == true`: Asserter wins. Bond returned by OO v3 to asserter. Market funds claimable by asserter.
   - `truthful == false`: Disputer wins. Both bonds go to disputer (via OO v3 economics). Market funds claimable by disputer.

4. **Withdrawal** -- The winner calls `withdraw(assertionId)` to claim market funds. Uses pull-over-push pattern with `ReentrancyGuard`.

**Undisputed path:** If no dispute occurs, anyone can call `settleAssertion()` after liveness expires. OO v3 resolves the assertion as truthful and the asserter can withdraw.

## 4. Edge Case Handling

### 4.1 Last-Second Disputes
UMA's OO v3 enforces liveness checks in `disputeAssertion()` -- if called after the `expirationTime`, the transaction reverts on-chain. Our contract does not need additional time checks; OO v3 handles this atomically. No race condition is possible because block timestamps are deterministic within a transaction.

### 4.2 Concurrent Assertions
Each assertion receives a unique `bytes32 assertionId` from OO v3 (derived from a nonce + timestamp + asserter). Our contract maps `assertionId => AssertionData` independently. Multiple assertions from the same user are tracked separately with their own bonds, market amounts, and resolution statuses. The test `test_concurrentAssertions_independent` validates this.

### 4.3 Invalid Callbacks
`assertionResolvedCallback` validates:
1. `msg.sender == address(oo)` -- rejects non-oracle callers with `OnlyOracle()`.
2. `assertions[assertionId].asserter != address(0)` -- rejects unknown IDs with `AssertionNotFound()`.
3. Status check -- if already `ResolvedTrue` or `ResolvedFalse`, silently returns (idempotent). Prevents double-execution.

### 4.4 Balance Changes
The contract **never relies on `address(this).balance`** for payout calculations. Each assertion's `marketAmount` is recorded in its struct at creation time. External ETH sent to the contract (e.g., accidental transfers) does not affect any assertion's payout. The test `test_balanceChanges_immuneToExternalTransfers` confirms a stranger sending 5 ETH to the contract does not alter withdrawal amounts.

### 4.5 Re-Submission / Double Settlement
- **Status enum** prevents re-settlement: `withdraw()` checks `status == ResolvedTrue || ResolvedFalse` and `withdrawn == false`.
- **Double withdrawal** reverts with `AlreadyWithdrawn()`.
- **Double settle** reverts in OO v3 ("Already settled").
- `assertionResolvedCallback` is idempotent -- calling it twice on a resolved assertion silently returns.

## 5. Gas Optimization Decisions

| Optimization | Savings | Rationale |
|---|---|---|
| **Struct packing** (3 slots) | ~40k gas on writes | `address + uint64 + uint8` fit in one slot. `uint128 + uint128` in another. Avoids 3+ extra SSTOREs. |
| **Custom errors** | ~200 gas/revert | `error InsufficientETH()` uses 4-byte selector vs ~1200 gas for `require("string")`. |
| **Immutable variables** | ~2100 gas/read | `oo`, `weth`, `defaultIdentifier`, `defaultLiveness`, `defaultBond` stored in bytecode, not storage. Zero SLOAD. |
| **`unchecked {}` blocks** | ~40-60 gas/op | Used where underflow/overflow is impossible (e.g., `msg.value - bond` after `bond <= msg.value` check). |
| **Minimal storage** | Reduced SSTOREs | Only store what's needed for settlement. Assertion claim text is NOT stored on-chain -- it's emitted as an event. |
| **`calldata` for claim** | ~200 gas vs memory | `bytes calldata claim` avoids copying to memory. |

**Liveness Period: 7200s (2 hours)** -- Standard for testnet deployments. Provides adequate time for disputers to react while keeping test cycles short. For mainnet, 4-24 hours would be more appropriate depending on value at risk.

**Bond Size: OO v3 minimum** -- Using `oo.getMinimumBond(address(weth))` ensures the lowest viable bond, reducing capital requirements while maintaining OO v3's economic security guarantees. For mainnet, bonds should exceed the final fee to incentivize honest disputes.

**Gas Report (key functions):**

| Function | Median Gas |
|---|---|
| `createAssertion` | 265,059 |
| `disputeAssertion` | 134,747 |
| `settleAssertion` | 76,116 |
| `withdraw` | 56,319 |
| `assertionResolvedCallback` | 24,022 |

## 6. Deployment & Usage

### Prerequisites
- [Foundry](https://getfoundry.sh/)
- Sepolia ETH (from faucets)

### Build & Test
```bash
forge build
forge test -vvv
forge test --gas-report
```

### Deploy to Sepolia (Live OO v3)
```bash
cp .env.example .env
# Edit .env with your PRIVATE_KEY, SEPOLIA_RPC_URL, ETHERSCAN_API_KEY

source .env
forge script script/Deploy.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
```

### Deploy Sandbox (Isolated Testing)
```bash
forge script script/OracleSandbox.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
```
The sandbox deploys a `MockOptimisticOracleV3` where disputes can be resolved manually via `resolveAssertion(assertionId, truthful)` -- no DVM voting needed.

### Interact (via cast)
```bash
# Create assertion (0.1 ETH bond + 1 ETH market)
cast send $MARKET_ADDRESS "createAssertion(bytes)" \
  $(cast --from-utf8 "ETH was above $2500 on 1 Feb 2026") \
  --value 1.1ether --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Dispute (0.1 ETH bond)
cast send $MARKET_ADDRESS "disputeAssertion(bytes32)" $ASSERTION_ID \
  --value 0.1ether --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Settle (after liveness)
cast send $MARKET_ADDRESS "settleAssertion(bytes32)" $ASSERTION_ID \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Withdraw
cast send $MARKET_ADDRESS "withdraw(bytes32)" $ASSERTION_ID \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

### Key Addresses (Sepolia)
| Contract | Address |
|---|---|
| UMA OO v3 | `0xFd9e2642a170aDD10F53Ee14a93FcF2F31924944` |
| WETH9 | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` |
| Finder | `0xf4C48eDAd256326086AEfbd1A53e1896815F8f13` |
| UMA Testnet Oracle UI | https://testnet.oracle.uma.xyz |
# Assertion_Market
