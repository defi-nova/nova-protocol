# Yield Aggregator TON NOVA

Nova is a high-performance, multi-strategy yield aggregator for the TON blockchain. It optimizes returns by dynamically shifting capital between Lending protocols and Liquidity Pools (LP).

## 🚀 Global Updates (Latest)

- **STON.fi v2 Migration**: Fully migrated to STON.fi v2 protocol, implementing advanced swap logic and LP provision using the latest `0x6664de2a` opcode and `SwapAdditionalData` structures.
- **LP Automation (Swap + Provide)**: Implemented "One-Click" LP provision. The strategy automatically splits TON, swaps 50% to USDT, and provides liquidity to the pool in a single rebalancing flow.
- **TON-Native Architecture**: Optimized for the TON ecosystem. TON is now the sole primary asset for entry, eliminating the need for users to hold USDT to start earning.
- **Dynamic Slippage & MEV Protection**: Integrated API-driven `min_amount_out` calculation for DEX operations to protect user funds from slippage and front-running.
- **DeDust.io Integration**: Added support for DeDust.io LP strategies, providing diversification and access to multiple liquidity sources.
- **Gas-Optimized Rebalancing**: Refined gas limits (0.35 TON) to support complex multi-step DeFi operations (Swap + LP) in a single transaction.

## Core Features

### 🏦 Vault Contract (`vault.tact`)
- **Multi-Strategy Architecture**: Supports multiple yield strategies simultaneously with weight-based allocation (Basis Points: 10000 = 100%).
- **Price Per Share (PPS) Protection**: Implements `stored_balance` tracking to safeguard against PPS manipulation and flash loan attacks.
- **Auto-Rebalancing**: Includes a `Rebalance` mechanism that automatically shifts funds between strategies to match target allocations based on real-time APY.
- **Scalable Withdrawal Queue**: Processes withdrawals in batches to stay within TON gas limits, ensuring the protocol remains functional even with thousands of users.
- **Circuit Breaker**: Global pause for deposits via `TogglePause` for emergency situations.

### 🛡️ Strategy Contract (`strategy.tact`)
- **EVAA Protocol Integration**: Native support for supply/borrow yield generation on EVAA Main Pool (TON Asset ID: 0).
- **DEX LP Strategies**: Automated entry and exit for TON/USDT pairs on **STON.fi v2** and **DeDust.io**.
- **Unified DEX Interface**: Support for `StonfiSwap`, `StonfiProvideLiquidity`, and `DedustSwap` messages.
- **Bounced Message Handling**: Robust logic to handle failed external transactions and maintain accurate accounting.

## Key Mechanisms

- **PPS (Price Per Share)**: Tracks the value of vault assets relative to issued shares (scaled by 10^12).
- **Strategy Migration**: Secure `MigrateStrategy` message with slippage protection (`min_amount_out`) for seamless movement between yield providers.
- **Stored Balance**: Internal accounting that separates vault liquidity from total assets, providing a reliable baseline for yield calculations.
- **Timelock (Optional Logic)**: Structure for timelocked actions to ensure decentralization and security.

## Testing & Validation

The project uses a comprehensive testing framework based on `@ton/sandbox` and **Jest**.

### Test Suites:
- `Vault.spec.ts`: Core vault logic (deposits, withdrawals, PPS tracking).
- `VaultSecurity.spec.ts`: Security boundary testing (unauthorized access, profit caps, circuit breakers).
- `PublicTestingScenarios.spec.ts`: Complex multi-user scenarios simulating real-world testnet behavior and PPS jumps.
- `AdvancedFeatures.spec.ts`: Validation of the `Rebalance` mechanism and DEX swap logic.

### Running Tests:
```bash
# Build contracts
npx blueprint build Vault
npx blueprint build Strategy

# Run all tests
npm test

# Run specific suite
npx jest tests/AdvancedFeatures.spec.ts
```

## Project Structure
- `contracts/`: Tact source code.
- `contracts/messages.tact`: Unified message definitions for cross-contract communication.
- `tests/`: TypeScript test suites using TON Sandbox.
- `build/`: Compiled artifacts (BOC and wrappers).

## Technologies Used
- **Tact**: Domain-specific language for TON smart contracts.
- **TON Blockchain**: The underlying decentralized network.
- **Blueprint**: Development environment for TON.
- **EVAA Protocol**: Integrated yield source.
- **DeDust / STON.fi**: Integrated DEX protocols.
