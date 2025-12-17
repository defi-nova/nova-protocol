import { toNano, beginCell, Address } from '@ton/core';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import { NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const admin = provider.sender().address;
    if (!admin) throw new Error("Sender address required");

    // 1. Deploy Vault with dummy strategy
    // We use the admin address as dummy strategy initially
    const dummyStrategy = admin;
    // Dummy content (TEP-64)
    const content = beginCell().storeUint(0, 8).endCell(); 
    
    const vault = provider.open(await Vault.fromInit(admin, dummyStrategy, content));

    console.log('Deploying Vault...');
    await vault.send(
        provider.sender(),
        {
            value: toNano('0.1'),
        },
        null, // Init message (empty body allowed by receive())
    );

    await provider.waitForDeploy(vault.address);
    console.log('Vault deployed at:', vault.address);

    // 2. Deploy Strategy
    const strategy = provider.open(await Strategy.fromInit(vault.address, admin));
    
    console.log('Deploying Strategy...');
    await strategy.send(
        provider.sender(),
        {
            value: toNano('0.1'),
        },
        null,
    );
    
    await provider.waitForDeploy(strategy.address);
    console.log('Strategy deployed at:', strategy.address);

    // 3. Update Vault with real Strategy
    console.log('Updating Vault strategy address...');
    await vault.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'SetStrategy',
            new_strategy: strategy.address
        }
    );
    
    console.log('Done!');
}
