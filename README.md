# TON NOVA: High-Performance Yield Aggregator

**NOVA** is a decentralized, multi-strategy yield aggregator built on the TON blockchain. It is designed to maximize returns for users by automatically moving capital between lending protocols and decentralized exchanges (DEX) to capture the highest available yields.

---

## 🎯 Project Goals

The primary goal of NOVA is to simplify the DeFi experience on TON. Instead of manually managing positions across multiple protocols, users deposit TON into a single Vault, which then intelligently distributes the capital across various yield-generating strategies.

- **Efficiency**: Minimize gas costs and complexity for the end user.
- **Maximized Yield**: Access to lending (EVAA) and liquidity provision (STON.fi, DeDust) in one place.
- **Automation**: Self-optimizing rebalancing based on real-time APY data.
- **Security**: Robust safeguards against liquidation, price manipulation, and flash loans.

---

## 🏗️ Core Architecture

The protocol is split into two main components:

### 1. The Vault (`vault.tact`)
The Vault is the primary entry point for users. It manages the accounting of user funds using a **Price Per Share (PPS)** model.
- **Shares (Jettons)**: When users deposit TON, they receive Vault Shares (Jettons) representing their portion of the pool.
- **Multi-Strategy Management**: The Vault can hold multiple strategies simultaneously, each with a specific weight (e.g., 60% EVAA, 40% STON.fi).
- **Batch Processing**: Designed to handle high-frequency interactions efficiently.
- **Safety Measures**: Includes profit jump caps (max 20% profit increase per harvest) and emergency pause functions.

### 2. The Strategy (`strategy.tact`)
Strategies are modular contracts that interact with external DeFi protocols.
- **Lending Strategy**: Deposits TON into **EVAA** to earn interest and potentially borrow assets for leveraged yield.
- **LP Strategy**: Automatically provides liquidity to **STON.fi v2** or **DeDust.io**. It handles the complex "One-Click" flow: swapping 50% of incoming TON to USDT and providing the pair to the pool.
- **Profit Harvesting**: Strategies collect rewards and report them back to the Vault, increasing the PPS for all share holders.

---

## ✨ Key Features

### 🔄 Dynamic Rebalancing
The protocol includes an `optimize_and_rebalance` mechanism. Based on APY data provided by an oracle or admin, the Vault automatically adjusts the distribution of funds between strategies to prioritize the most profitable ones.

### ⚡ One-Click Liquidity Provision
Moving from TON to a TON/USDT LP position usually requires multiple manual swaps and deposits. NOVA automates this entire flow within a single transaction, including slippage protection.

### 🛡️ Advanced Security
- **Health Factor Monitoring**: For lending strategies, NOVA monitors the Health Factor (HF) to prevent liquidations.
- **Price-Per-Share Protection**: Safeguards against "sandwich" attacks and PPS manipulation during deposits and withdrawals.
- **Admin-Controlled Upgrades**: Critical protocol addresses (DEX routers, pTON, etc.) can be updated by the admin without redeploying the contract.
- **Time-Locked Harvesting**: Prevents excessive harvesting calls and ensures stable profit reporting.

---

## 🛠️ Supported Protocols

- **EVAA**: Lending and borrowing on the TON Main Pool.
- **STON.fi v2**: High-efficiency swaps and liquidity provision.
- **DeDust.io**: Flexible liquidity pools and vaults.

---

## 🚀 Getting Started

### Installation
```bash
npm install
```

### Compiling Contracts
```bash
# Compile the Vault
npx blueprint build Vault

# Compile the Strategy
npx blueprint build Strategy
```

### Running Tests
The project features a rigorous test suite covering all core functions and edge cases.
```bash
# Run all tests
npm test

# Run specific features (Rebalance, DEX)
npx jest tests/AdvancedFeatures.spec.ts
```

---

## 📂 Project Structure
- `contracts/`: Tact smart contract source code.
- `contracts/messages.tact`: Shared message types and structures.
- `tests/`: Comprehensive TypeScript test suites using TON Sandbox.
- `scripts/`: Deployment and management scripts.