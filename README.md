# Yield Aggregator TON NOVA

This project implements a high-performance yield aggregator for the TON blockchain, featuring a multi-strategy Vault and Strategy contract architecture designed for secure, scalable, and efficient asset management. The system integrates with the EVAA protocol for yield generation and includes built-in DEX support for asset swaps.

## Core Features

### 🏦 Vault Contract (`vault.tact`)
- **Multi-Strategy Architecture**: Supports multiple yield strategies simultaneously with weight-based allocation (Basis Points: 10000 = 100%).
- **Price Per Share (PPS) Protection**: Implements `stored_balance` tracking to safeguard against PPS manipulation and flash loan attacks.
- **Auto-Rebalancing**: Includes a `Rebalance` mechanism that automatically shifts funds between strategies to match target allocations.
- **Scalable Withdrawal Queue**: Processes withdrawals in batches to stay within TON gas limits, ensuring the protocol remains functional even with thousands of users.
- **Profit Security**: Built-in 20% profit cap check for strategy reports to prevent anomalous yield updates from compromised strategies.
- **Circuit Breaker**: Global pause for deposits via `TogglePause` for emergency situations.
- **Admin Recovery**: Secure administration with `SetAdmin`, `TransferOwnership`, and emergency recovery options.

### 🛡️ Strategy Contract (`strategy.tact`)
- **EVAA Protocol Integration**: Native support for supplying and withdrawing TON/Jettons to/from the EVAA lending protocol.
- **DEX Integration**: Built-in interfaces for **DeDust** and **STON.fi**, allowing strategies to perform asset swaps (`SwapToJetton`).
- **Bounced Message Handling**: Robust logic to handle failed external transactions and maintain accurate accounting.
- **Flexible Configuration**: Supports dynamic asset IDs and DEX router addresses via admin messages.

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
