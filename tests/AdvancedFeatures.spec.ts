import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, beginCell } from '@ton/core';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import '@ton/test-utils';

describe('Advanced Features: Rebalance and DEX Integration', () => {
    let blockchain: Blockchain;
    let admin: SandboxContract<TreasuryContract>;
    let user: SandboxContract<TreasuryContract>;
    let vault: SandboxContract<Vault>;
    let strategy1: SandboxContract<Strategy>;
    let strategy2: SandboxContract<Strategy>;
    let evaaMaster: SandboxContract<TreasuryContract>;
    let recovery: SandboxContract<TreasuryContract>;
    let data1: any;
    let data2: any;

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        admin = await blockchain.treasury('admin');
        user = await blockchain.treasury('user');
        evaaMaster = await blockchain.treasury('evaa');
        recovery = await blockchain.treasury('recovery');

        const content = beginCell().storeUint(0, 8).endCell();
        vault = blockchain.openContract(await Vault.fromInit(admin.address, recovery.address, content));
        await vault.send(admin.getSender(), { value: toNano('0.1') }, null);

        strategy1 = blockchain.openContract(await Strategy.fromInit(vault.address, admin.address, evaaMaster.address));
        await strategy1.send(admin.getSender(), { value: toNano('0.1') }, null);

        // Use a different seed/salt for the second strategy to get a different address
        const strategy2Init = await Strategy.fromInit(vault.address, recovery.address, evaaMaster.address); // Different admin for unique addr
        strategy2 = blockchain.openContract(strategy2Init);
        await strategy2.send(admin.getSender(), { value: toNano('0.1') }, null);

        // Add strategies: Strat1 (70%), Strat2 (30%)
        const add1 = await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'AddStrategy',
            strategy: strategy1.address,
            weight: 7000n
        });
        const add2 = await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'AddStrategy',
            strategy: strategy2.address,
            weight: 3000n
        });
        
        expect(add1.transactions).toHaveTransaction({ to: vault.address, success: true });
        expect(add2.transactions).toHaveTransaction({ to: vault.address, success: true });
    });

    it('should rebalance funds between strategies correctly', async () => {
        // 1. Initial deposit
        await vault.send(user.getSender(), { value: toNano('100.5') }, {
            $$type: 'Deposit',
            amount: toNano('100'),
            min_shares: 0n
        });

        // Add 20 TON to stored_balance for rebalancing investment
        await admin.send({
            to: vault.address,
            value: toNano('20')
        });

        // Initial weights are 70/30
        data1 = await vault.getGetStrategyInfo(strategy1.address);
        data2 = await vault.getGetStrategyInfo(strategy2.address);

        // Debug: what are we getting?
        // console.log("Strat 1 Info:", data1);
        // console.log("Strat 2 Info:", data2);

        expect(data1?.weight).toBe(7000n);
        expect(data2?.weight).toBe(3000n);

        // 2. Change weights to 50/50
        await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetStrategyAllocation',
            strategy: strategy1.address,
            weight: 5000n
        });
        await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetStrategyAllocation',
            strategy: strategy2.address,
            weight: 5000n
        });

        // 3. Trigger Rebalance
        const rebalanceResult = await vault.send(admin.getSender(), { value: toNano('0.5') }, "Rebalance");

        // Verify rebalance messages were sent
        expect(rebalanceResult.transactions).toHaveTransaction({
            from: vault.address,
            to: strategy1.address,
            op: 0x09, // Divest
            success: true
        });

        expect(rebalanceResult.transactions).toHaveTransaction({
            from: vault.address,
            to: strategy2.address,
            op: 0x08, // Invest
            success: true
        });
    });

    it('should handle DEX swap requests in strategy', async () => {
        const dedustVault = await blockchain.treasury('dedust');
        
        // Ensure strategy has TON for swap fees
        await admin.send({
            to: strategy1.address,
            value: toNano('1.0')
        });

        // Set DEX address
        await strategy1.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetDexAddresses',
            dedust: dedustVault.address,
            stonfi: null
        });

        // Trigger Swap
        const swapResult = await strategy1.send(admin.getSender(), { value: toNano('0.2') }, {
            $$type: 'SwapToJetton',
            dex_type: 0n, // DeDust
            amount: toNano('0.1'), // Smaller amount to ensure enough for fees
            min_amount_out: 0n
        });

        // Verify message to DeDust
        expect(swapResult.transactions).toHaveTransaction({
            from: strategy1.address,
            to: dedustVault.address,
            op: 0xe3a0f35, // DedustSwap
            success: true
        });
    });
});
