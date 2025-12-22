import { toNano, beginCell, Address } from '@ton/core';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import { NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    const admin = Address.parse("0QAmLCXR3ikA0ohMg6R82E2NHESHtXjA299_HqIe_Wqr1aXi");
    const recovery = admin; // Using same admin as recovery for now

    // 1. Deploy Vault
    // Content (TEP-64) with unique nonce for new addresses
    const content = beginCell().storeUint(Math.floor(Math.random() * 1000000), 32).endCell(); 
    
    const vault = provider.open(await Vault.fromInit(admin, recovery, content));

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
    // Mainnet Protocol Addresses
    const evaa_master = Address.parse("EQCD39VS5jcptHL8vMjEXrzGaRcCV4m6Ctj9b70m5A4-R-P3");
    const stonfi_router = Address.parse("EQB3n9NWuHqhRM9PaPISTPoo6Y6Br8_s7U_8Y5is6FscBR8");
    const stonfi_pton = Address.parse("EQCM3B12QK1e4yZSf8GtBRT0aLMNyEsBc_DhVfRRtOEffLez");
    const dedust_factory = Address.parse("EQBfBWT7X2BHg9tXAxzhz2aKiNTU1tpt5NsiK0uSDW_YAJ67");
    const usdt_master = Address.parse("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs");
    
    const strategy = provider.open(await Strategy.fromInit(
        vault.address, 
        admin, 
        evaa_master,
        stonfi_router,
        stonfi_pton,
        dedust_factory,
        usdt_master
    ));
    
    console.log('Deploying Strategy...');
    await strategy.send(
        provider.sender(),
        {
            value: toNano('0.5'),
        },
        null,
    );
    
    await provider.waitForDeploy(strategy.address);
    console.log('Strategy deployed at:', strategy.address);

    // 2.1 Set DEX Addresses (Mainnet)
    console.log('Setting DEX Addresses (DeDust and STON.fi)...');
    await strategy.send(
        provider.sender(),
        {
            value: toNano('0.1'),
        },
        {
            $$type: 'SetDexAddresses',
            dedust_factory: dedust_factory,
            stonfi_router: stonfi_router,
            stonfi_pton: stonfi_pton,
            usdt_master: usdt_master
        }
    );

    // 2.2 Set Strategy Mode (0 = EVAA Lending, 1 = STON.fi LP)
    console.log('Setting Strategy Mode to EVAA Lending...');
    await strategy.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'SetStrategyMode',
            mode: 0n // Start with lending
        }
    );

    // 3. Update Vault with real Strategy
    console.log('Adding Strategy to Vault...');
    await vault.send(
        provider.sender(),
        {
            value: toNano('0.1'),
        },
        {
            $$type: 'AddStrategy',
            strategy: strategy.address,
            weight: 10000n // 100%
        }
    );

    console.log('Done!');
}
