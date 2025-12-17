# Yield Aggregator TON NOVA

This project implements a yield aggregator for the TON blockchain, featuring a Vault and Strategy contract architecture designed for secure and efficient asset management. The system integrates with the EVAA protocol for external asset handling and includes robust testing with Jest.

## Implemented Features

### Vault Contract (`vault.tact`)
- **Core Functionality**: Manages user deposits, withdrawals, and interactions with various strategies.
- **Price Per Share (PPS) Protection**: Implements `stored_balance` to safeguard against PPS manipulation, ensuring fair value for all participants.
- **Strategy Migration**: Supports secure migration of funds between different strategies, including slippage protection (`min_amount_out`).
- **Refund Handling**: Processes `StrategyRefund` messages from associated strategies, verifying sender authenticity to prevent unauthorized operations.
- **Scalable Withdrawal Queue**: Processes withdrawals in batches (default 50 requests per transaction) to avoid gas limit errors; admin can manually trigger additional batches via `ProcessWithdrawals` message.
- **Circuit Breaker**: Admin-controlled global pause for deposits via `TogglePause` message to mitigate protocol emergencies.
- **Emergency Unlock**: Admin-only `ResetProcessing` message to forcibly clear the `is_processing` flag if the vault gets stuck due to failed strategy interactions.
- **Profit Security Check**: Rejects strategy profit reports that increase the strategy balance by more than 20% to prevent PPS manipulation by compromised strategies.

### Strategy Contract (`strategy.tact`)
- **EVAA Integration**: Interacts with the EVAA protocol for asset supply and withdrawal operations.
- **Typed Messages**: Sends typed `StrategyRefund` messages to the Vault for clear and secure communication.
- **Bounced Message Handling**: Includes logic to revert accounting and refund funds in case of failed EVAA transactions.
- **Configurable Asset IDs**: Supports setting asset IDs for EVAA interactions via `SetAssetId` handler.

### EVAA Integration
- **External Asset Management**: Facilitates interaction with the EVAA protocol for managing assets outside the core vault.
- **Withdrawal Success/Failure Handling**: Processes `EvaaWithdrawSuccess` messages and handles bounced messages to maintain accurate accounting.

## Key Concepts

- **PPS (Price Per Share)**: A mechanism to track the value of assets within the vault, scaled by 10^12.
- **Slippage Protection**: Implemented via `min_amount_out` parameter during strategy migration to prevent unexpected losses due to price fluctuations.
- **Stored Balance**: An internal variable in the Vault contract used to protect against PPS manipulation by tracking the actual balance.
- **Op Codes**: Numeric identifiers used in transaction messages for clear and efficient contract interaction (e.g., `0x55` for `StrategyRefund`).
- **Circuit Breaker**: A mechanism allowing the administrator to pause certain protocol functions (e.g., deposits) in emergency situations.
- **Emergency Unlock**: An administrator function to forcibly reset the `is_processing` flag in the Vault if it gets stuck due to an error.
- **Batch Processing**: Processing queue items (e.g., withdrawal requests) in portions to avoid exceeding gas limits.

## Testing

The project utilizes Jest for comprehensive testing of both Vault and Strategy contracts. All critical scenarios, including deposits, withdrawals, strategy migrations, EVAA interactions, and security measures, are covered. All 10 tests currently pass, ensuring the reliability and correctness of the contract logic. Additionally, a dedicated test suite (`VaultSecurity.spec.ts`) has been added to cover new security and scalability features like Circuit Breaker, Emergency Unlock, and Profit Security checks.

## Technologies Used

- **Tact**: Smart contract language for the TON blockchain.
- **TON Blockchain**: The target platform for contract deployment.
- **Jest**: JavaScript testing framework.
- **FunC**: (Underlying language for TON smart contracts, implicitly used by Tact).
