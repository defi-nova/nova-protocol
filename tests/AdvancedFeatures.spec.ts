import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, beginCell, Address } from '@ton/core';
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
    let recovery: SandboxContract<TreasuryContract>;
    let mockStonfiRouter: SandboxContract<TreasuryContract>;
    let mockStonfiPton: SandboxContract<TreasuryContract>;
    let mockDedustFactory: SandboxContract<TreasuryContract>;
    let mockDedustVault: SandboxContract<TreasuryContract>;
    let mockUsdtMaster: SandboxContract<TreasuryContract>;
    let data1: any;
    let data2: any;

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        admin = await blockchain.treasury('admin');
        user = await blockchain.treasury('user');
        recovery = await blockchain.treasury('recovery');

        const content = beginCell().storeUint(0, 8).endCell();
        vault = blockchain.openContract(await Vault.fromInit(admin.address, recovery.address, content));
        await vault.send(admin.getSender(), { value: toNano('0.1') }, null);

        mockStonfiRouter = await blockchain.treasury('stonfi_router');
        mockStonfiPton = await blockchain.treasury('stonfi_pton');
        mockDedustFactory = await blockchain.treasury('dedust_factory');
        mockDedustVault = await blockchain.treasury('dedust_vault');
        mockUsdtMaster = await blockchain.treasury('usdt_master');

        strategy1 = blockchain.openContract(await Strategy.fromInit(
            vault.address, 
            admin.address, 
            mockStonfiRouter.address,
            mockStonfiPton.address,
            mockDedustFactory.address,
            mockUsdtMaster.address,
            mockDedustVault.address
        ));
        await strategy1.send(admin.getSender(), { value: toNano('0.1') }, null);

        // Use a different seed/salt for the second strategy to get a different address
        const strategy2Init = await Strategy.fromInit(
            vault.address, 
            recovery.address, 
            mockStonfiRouter.address,
            mockStonfiPton.address,
            mockDedustFactory.address,
            mockUsdtMaster.address,
            mockDedustVault.address
        ); // Different admin for unique addr
        strategy2 = blockchain.openContract(strategy2Init);
        await strategy2.send(admin.getSender(), { value: toNano('0.1') }, null);

        // Give strategies some TON for fees
        await admin.send({ to: strategy1.address, value: toNano('1') });
        await admin.send({ to: strategy2.address, value: toNano('1') });

        // Add strategies: Strat1 (70%), Strat2 (30%)
        const add1 = await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'AddStrategy',
            strategy: strategy1.address,
            weight: 7000n,
            is_nova: false
        });
        const add2 = await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'AddStrategy',
            strategy: strategy2.address,
            weight: 3000n,
            is_nova: false
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

        // Add 30 TON to stored_balance for rebalancing investment (more than needed for safety)
        await admin.send({
            to: vault.address,
            value: toNano('30')
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
            op: 0x88, // Invest
            success: true
        });
    });

    /* 
    it('should handle DEX swap requests in strategy', async () => {
        // ... removed SwapToJetton ...
    });
    */

    it('should handle STON.fi v2 LP investment flow', async () => {
        const usdtWallet = await blockchain.treasury('usdt_wallet');
        const lpTokenWallet = await blockchain.treasury('lp_token_wallet');

        // 1. Setup Strategy for STON.fi LP
        await strategy1.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetStrategyMode',
            mode: 0n // STON.fi LP
        });

        await strategy1.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetJettonWallets',
            usdt: usdtWallet.address,
            lp_token: lpTokenWallet.address,
            nova: admin.address
        });

        // Deposit funds to vault so it has something to invest
        await vault.send(user.getSender(), { value: toNano('20.5') }, {
            $$type: 'Deposit',
            amount: toNano('20'),
            min_shares: 0n
        });

        // 2. Trigger Invest
        const investAmount = toNano('10');
        
        // Force a deficit in Strategy 1 to trigger Invest from Vault
        await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetStrategyAllocation',
            strategy: strategy1.address,
            weight: 9000n // Increase to 90% to trigger invest
        });
        
        // Trigger Rebalance
        const rebalanceRes = await vault.send(admin.getSender(), { value: investAmount + toNano('1.0') }, "Rebalance");

        // 3. Verify Swap message to pTON
        // We look for the transaction initiated by the Strategy (which was triggered by Vault)
        expect(rebalanceRes.transactions).toHaveTransaction({
            from: strategy1.address,
            to: mockStonfiPton.address, // STONFI_PTON
            op: 0xf8a7ea5, // JettonTransfer
            success: true
        });

        // Verify the confirmation back to vault
        expect(rebalanceRes.transactions).toHaveTransaction({
            from: strategy1.address,
            to: vault.address,
            success: true,
            body: (x) => x?.asSlice().loadUint(32) === 0 && x?.asSlice().skip(32).loadBuffer(20).toString() === 'StrategyConfirmation'
        });
    });

    it('should optimize weights based on APY updates', async () => {
        // 1. Set APYs: Strat1 = 20%, Strat2 = 10%
        await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'UpdateProtocolApy',
            strategy: strategy1.address,
            apy: 2000n // 20%
        });
        await vault.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'UpdateProtocolApy',
            strategy: strategy2.address,
            apy: 1000n // 10%
        });

        // 2. Trigger optimization (happens automatically in UpdateProtocolApy)
        // Expected weights: Strat1 = 66.6%, Strat2 = 33.3%
        // But we have a 60% cap in the contract: if (new_weight > 6000) { new_weight = 6000; }
        
        const info1 = await vault.getGetStrategyInfo(strategy1.address);
        const info2 = await vault.getGetStrategyInfo(strategy2.address);

        expect(info1?.weight).toBe(6000n); // Capped at 60%
        // Strat2 gets the remaining or proportional? 
        // Logic: (1000 * 9500) / 3000 = 3166
        expect(info2?.weight).toBe(3166n);
    });

    it('should allow admin to update DEX addresses', async () => {
        const newDedustFactory = await blockchain.treasury('new_dedust_factory');
        const newDedustVault = await blockchain.treasury('new_dedust_vault');
        const newStonfiRouter = await blockchain.treasury('new_stonfi_router');
        const newStonfiPton = await blockchain.treasury('new_stonfi_pton');
        const newUsdtMaster = await blockchain.treasury('new_usdt_master');

        const res = await strategy1.send(admin.getSender(), { value: toNano('0.1') }, {
            $$type: 'SetDexAddresses',
            dedust_factory: newDedustFactory.address,
            dedust_vault: newDedustVault.address,
            stonfi_router: newStonfiRouter.address,
            stonfi_pton: newStonfiPton.address,
            usdt_master: newUsdtMaster.address
        });

        expect(res.transactions).toHaveTransaction({
            from: admin.address,
            to: strategy1.address,
            success: true
        });

        // We can't easily check state variables if they are not exposed via getters, 
        // but the transaction success confirms the message was handled.
    });
});
