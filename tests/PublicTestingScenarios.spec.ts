import { Blockchain, SandboxContract, TreasuryContract } from '@ton/sandbox';
import { toNano, beginCell, Cell, Dictionary, Builder, Slice } from '@ton/core';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import { JettonWallet } from '../build/Vault/Vault_JettonWallet';
import '@ton/test-utils';

describe('Public Testing Scenarios (Multi-User & PPS Jumps)', () => {
    let blockchain: Blockchain;
    let deployer: SandboxContract<TreasuryContract>;
    let vault: SandboxContract<Vault>;
    let strategy: SandboxContract<Strategy>;
    let admin: SandboxContract<TreasuryContract>;
    let evaaMaster: SandboxContract<TreasuryContract>;
    let recovery: SandboxContract<TreasuryContract>;

    const tonAssetId = 5979697966427382277430635252575298020583921833118053153835n;
    const EvaaAssetDataValue = {
        serialize: (src: any, builder: Builder) => {
            builder.storeCoins(src.balance);
            builder.storeCoins(src.borrow);
        },
        parse: (src: Slice) => {
            return {
                $$type: 'EvaaAssetData' as const,
                balance: src.loadCoins(),
                borrow: src.loadCoins()
            };
        }
    };

    beforeEach(async () => {
        blockchain = await Blockchain.create();
        admin = await blockchain.treasury('admin');
        recovery = await blockchain.treasury('recovery');
        deployer = await blockchain.treasury('deployer');
        evaaMaster = await blockchain.treasury('evaa');

        const content = beginCell().storeUint(0, 8).endCell();
        vault = blockchain.openContract(await Vault.fromInit(admin.address, recovery.address, content));
        await deployer.send({ to: vault.address, value: toNano('0.1'), init: vault.init });

        strategy = blockchain.openContract(await Strategy.fromInit(vault.address, admin.address, evaaMaster.address));
        await deployer.send({ to: strategy.address, value: toNano('0.1'), init: strategy.init });

        await vault.send(admin.getSender(), { value: toNano('0.05') }, { 
            $$type: 'AddStrategy', strategy: strategy.address, weight: 10000n 
        });
    });

    async function simulateProfit(profitNano: bigint) {
        const currentData = await strategy.getGetStrategyData();
        const newBalance = currentData.total_invested + profitNano;
        
        const assetsDict = Dictionary.empty(Dictionary.Keys.BigUint(256), EvaaAssetDataValue);
        assetsDict.set(tonAssetId, { $$type: 'EvaaAssetData', balance: newBalance, borrow: 0n });
        
        await strategy.send(evaaMaster.getSender(), { value: toNano('0.05') }, {
            $$type: 'EvaaUserScData', user: strategy.address, assets: assetsDict
        });

        await strategy.send(admin.getSender(), { value: toNano('1.0') }, {
            $$type: 'Harvest', gas_limit: toNano('0.05'), min_profit: 0n
        });
    }

    it('Complex Scenario: Multi-user deposits and withdrawals across PPS jumps', async () => {
        const alice = await blockchain.treasury('alice');
        const bob = await blockchain.treasury('bob');
        const charlie = await blockchain.treasury('charlie');

        // 1. Alice deposits 100 TON
        await vault.send(alice.getSender(), { value: toNano('100.2') }, {
            $$type: 'Deposit', amount: toNano('100'), min_shares: 0n
        });
        
        const aliceWallet = blockchain.openContract(JettonWallet.fromAddress(await vault.getGetWalletAddress(alice.address)));
        let aliceShares = (await aliceWallet.getGetWalletData()).balance;
        expect(aliceShares).toBe(toNano('100'));

        // 2. PPS jumps by 10%
        await simulateProfit(toNano('10')); // 100 -> 110
        let pps = await vault.getGetPps();
        console.log('PPS after first jump:', pps.toString());

        // 3. Bob deposits 100 TON
        await vault.send(bob.getSender(), { value: toNano('100.2') }, {
            $$type: 'Deposit', amount: toNano('100'), min_shares: 0n
        });
        const bobWallet = blockchain.openContract(JettonWallet.fromAddress(await vault.getGetWalletAddress(bob.address)));
        let bobShares = (await bobWallet.getGetWalletData()).balance;
        // Bob should get fewer shares than Alice because PPS > 1
        expect(bobShares).toBeLessThan(aliceShares);
        console.log('Bob shares:', bobShares.toString());

        // 4. PPS jumps again by 5%
        await simulateProfit(toNano('10')); // Total assets ~210 -> ~220
        pps = await vault.getGetPps();
        console.log('PPS after second jump:', pps.toString());

        // 5. Charlie deposits 50 TON
        await vault.send(charlie.getSender(), { value: toNano('50.2') }, {
            $$type: 'Deposit', amount: toNano('50'), min_shares: 0n
        });
        const charlieWallet = blockchain.openContract(JettonWallet.fromAddress(await vault.getGetWalletAddress(charlie.address)));
        let charlieShares = (await charlieWallet.getGetWalletData()).balance;
        console.log('Charlie shares:', charlieShares.toString());

        // 6. Alice withdraws half (50 shares)
        const aliceWithdrawRequest = await alice.send({
            to: aliceWallet.address,
            value: toNano('0.2'),
            body: beginCell()
                .storeUint(0x595f07bc, 32)
                .storeUint(0, 64)
                .storeCoins(toNano('50')) // Half of her shares
                .storeAddress(alice.address)
                .storeMaybeRef(null)
                .endCell()
        });

        // Verify request was queued (sent Divest to Strategy)
        expect(aliceWithdrawRequest.transactions).toHaveTransaction({
            from: vault.address,
            to: strategy.address,
            op: 0x09, // Divest
            success: true
        });

        // Simulate strategy refund for Alice
        const aliceRefundResult = await strategy.send(evaaMaster.getSender(), { value: toNano('60') }, "EvaaWithdrawSuccess");

        // Verify payment to Alice happened after refund
        expect(aliceRefundResult.transactions).toHaveTransaction({
            from: vault.address,
            to: alice.address,
            success: true
        });

        // 7. Check final balances and PPS
        pps = await vault.getGetPps();
        console.log('Final PPS:', pps.toString());
        
        const finalAliceShares = (await aliceWallet.getGetWalletData()).balance;
        expect(finalAliceShares).toBe(toNano('50'));

        const totalShares = (await vault.getGetJettonData()).total_supply;
        expect(totalShares).toBe(aliceShares + bobShares + charlieShares - toNano('50'));
    });
});
