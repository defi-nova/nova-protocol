# TON NOVA: High-Performance Yield Aggregator

**NOVA** is a decentralized, multi-strategy yield aggregator built on the TON blockchain. It is designed to maximize returns for users by automatically moving capital between lending protocols and decentralized exchanges (DEX) to capture the highest available yields.

---

## 🎯 Project Goals

The primary goal of NOVA is to simplify the DeFi experience on TON. Instead of manually managing positions across multiple protocols, users deposit TON into a single Vault, which then intelligently distributes the capital across various yield-generating strategies.

- **Efficiency**: Minimize gas costs and complexity for the end user.
- **Maximized Yield**: Access to lending and liquidity provision (STON.fi, DeDust) in one place.
- **nTON (Nova TON)**: A liquid yield-bearing token representing your share in the aggregator.
- **Automation**: Self-optimizing rebalancing based on real-time APY data.
- **Security**: Robust safeguards against liquidation, price manipulation, and flash loans.

---

## 🏗️ Core Architecture

The protocol is split into two main components:

### 1. The Vault (`vault.tact`)
The Vault is the primary entry point for users. It manages the accounting of user funds using a **Price Per Share (PPS)** model and acts as the **Jetton Master** for the nTON token.
- **nTON (Nova TON)**: When users deposit TON, they receive `nTON` tokens. These are standard TEP-74 Jettons that represent their portion of the pool and automatically grow in value relative to TON as yields are harvested.
- **Multi-Strategy Management**: The Vault can hold multiple strategies simultaneously, each with a specific weight (e.g., 60% Strategy A, 40% Strategy B).
- **Liquid Yield**: Since `nTON` is a standard Jetton, users can trade it on DEXs or use it in other DeFi protocols without withdrawing from the aggregator.

### 2. The Strategy (`strategy.tact`)
Strategies are modular contracts that interact with external DeFi protocols.
- **Lending Strategy**: Deposits TON into lending protocols to earn interest.
- **LP Strategy**: Automatically provides liquidity to **STON.fi v2** or **DeDust.io**. It handles the complex "One-Click" flow: swapping 50% of incoming TON to USDT and providing the pair to the pool.
- **Profit Harvesting**: Strategies collect rewards and report them back to the Vault, increasing the PPS for all `nTON` holders.

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

## 💰 Fees & Tokenomics

NOVA implements a sustainable fee structure designed to reward the protocol and maintain the ecosystem. All fees are calculated in **basis points** (10000 = 100%):

- **Performance Fee (Admin)**: **5%** (500 bps) of the generated profit is sent to the admin wallet.
- **Burning Fee (NOVA)**: **5%** (500 bps) of the generated profit is automatically used to buy back and burn **NOVA** tokens via **DeDust.io**, creating deflationary pressure.
- **Withdrawal Fee**: A **0.1%** (10 bps) fee is applied to all withdrawals to prevent arbitrage spam and protect long-term liquidity providers.

---

## 🚀 NOVA/TON Strategy

A dedicated **NOVA/TON LP Strategy** is integrated into the core rebalancing logic:
- **Fixed Allocation**: **5%** (500 bps) of the total assets are strictly allocated to the NOVA/TON liquidity pool on DeDust.
- **Dynamic Weighting**: The remaining **95%** of assets are dynamically distributed among other strategies based on their real-time APY.
- **Strategic Importance**: This ensures deep liquidity for the NOVA token and supports the protocol's native tokenomics.

---

## ⚙️ Technical Implementation

- **Hardcode-Free**: All addresses, gas fees, and fee percentages are handled via constants and admin-configurable parameters.
- **Optimistic Updates**: Strategy balances are updated optimistically during investment to ensure accurate PPS calculation even before strategy confirmation.
- **Timelock**: Critical actions are protected by a **24-hour timelock** to ensure protocol security.
- **Basis Points (bps)**: All internal calculations for weights and fees use a precision of 10,000 for maximum accuracy.

---

## 🛠️ Supported Protocols

- **STON.fi v2**: High-efficiency swaps and liquidity provision.
- **DeDust.io**: Flexible liquidity pools and vaults.
- **Lending Protocols**: Support for top TON lending markets.

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