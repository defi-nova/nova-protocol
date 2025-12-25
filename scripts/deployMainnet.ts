import { toNano, beginCell, Address, Dictionary } from '@ton/core';
import { sha256_sync } from '@ton/crypto';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import { NetworkProvider } from '@ton/blueprint';

// TEP-64 Helpers for Metadata
const ONCHAIN_CONTENT_PREFIX = 0x01;
const SNAKE_PREFIX = 0x00;

function buildTokenMetadata(data: { [key: string]: string | undefined }): any {
    const dict = Dictionary.empty(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell());
    
    for (const [key, value] of Object.entries(data)) {
        if (value) {
            const keyHash = BigInt('0x' + sha256_sync(key).toString('hex'));
            const valueCell = beginCell()
                .storeUint(SNAKE_PREFIX, 8)
                .storeBuffer(Buffer.from(value))
                .endCell();
            dict.set(keyHash, valueCell);
        }
    }

    return beginCell()
        .storeUint(ONCHAIN_CONTENT_PREFIX, 8)
        .storeDict(dict)
        .endCell();
}

export async function run(provider: NetworkProvider) {
    const admin = provider.sender().address!!;
    const recovery = admin;

    console.log('--- Nova Aggregator Mainnet Deployment ---');
    console.log('Admin:', admin.toString());

    // 1. nTON Metadata
    const content = buildTokenMetadata({
        name: "Nova TON",
        symbol: "nTON",
        description: "Yield-bearing TON token by Nova Aggregator",
        image: "https://nova-aggregator.com/logo.png",
        decimals: "9"
    });

    // 2. Mainnet Protocol Addresses
    const MAINNET_STONFI_ROUTER = Address.parse("EQB3n9NWuHqhRM9PaPISTPoo6Y6Br8_s7U_8Y5is6FscBR8");
    const MAINNET_STONFI_PTON = Address.parse("EQCM3B12QK1e4yZSf8GtBRT0aLMNyEsBc_DhVfRRtOEffLez");
    const MAINNET_DEDUST_FACTORY = Address.parse("EQBfBWT7X2BHg9tXAxzhz2aKiNTU1tpt5NsiK0uSDW_YAJ67");
    const MAINNET_USDT_MASTER = Address.parse("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs");
    const MAINNET_DEDUST_VAULT = Address.parse("EQDa4VjCDuzv7tjaaCwhWfDEm-M19vMcmOC3GrSbuSryBh-V");
    const MAINNET_NOVA_TOKEN = Address.parse("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"); // PLACEHOLDER: Replace with real NOVA token address

    // 3. Deploy Vault
    console.log('Deploying Vault...');
    const vault = provider.open(await Vault.fromInit(admin, recovery, content));
    await vault.send(provider.sender(), { value: toNano('0.2') }, null);
    await provider.waitForDeploy(vault.address);
    console.log('Vault deployed at:', vault.address.toString());

    // 4. Deploy Main Strategy (STON.fi / DeDust)
    console.log('Deploying Main Strategy...');
    const mainStrategy = provider.open(await Strategy.fromInit(
        vault.address,
        admin,
        MAINNET_STONFI_ROUTER,
        MAINNET_STONFI_PTON,
        MAINNET_DEDUST_FACTORY,
        MAINNET_USDT_MASTER,
        MAINNET_DEDUST_VAULT
    ));
    await mainStrategy.send(provider.sender(), { value: toNano('0.2') }, null);
    await provider.waitForDeploy(mainStrategy.address);
    console.log('Main Strategy deployed at:', mainStrategy.address.toString());

    // 5. Deploy NOVA Strategy
    console.log('Deploying NOVA Strategy...');
    const novaStrategy = provider.open(await Strategy.fromInit(
        vault.address,
        admin,
        MAINNET_STONFI_ROUTER,
        MAINNET_STONFI_PTON,
        MAINNET_DEDUST_FACTORY,
        MAINNET_USDT_MASTER,
        MAINNET_DEDUST_VAULT
    ));
    await novaStrategy.send(provider.sender(), { value: toNano('0.2') }, null);
    await provider.waitForDeploy(novaStrategy.address);
    console.log('NOVA Strategy deployed at:', novaStrategy.address.toString());

    // 6. Configure NOVA Strategy
    console.log('Configuring NOVA Strategy mode...');
    await novaStrategy.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'SetStrategyMode',
        mode: 2n // 2: NOVA/TON LP
    });

    console.log('Setting NOVA token address in NOVA Strategy...');
    await novaStrategy.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'SetNovaToken',
        nova_master: MAINNET_NOVA_TOKEN,
        nova_vault: MAINNET_DEDUST_VAULT // Burn via DeDust
    });

    // 7. Configure Main Strategy mode
    console.log('Configuring Main Strategy mode (STON.fi)...');
    await mainStrategy.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'SetStrategyMode',
        mode: 0n // 0: STON.fi LP
    });

    // 8. Register Strategies in Vault
    console.log('Registering Main Strategy in Vault...');
    await vault.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'AddStrategy',
        strategy: mainStrategy.address,
        weight: 9500n, // 95%
        is_nova: false
    });

    console.log('Registering NOVA Strategy in Vault...');
    await vault.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'AddStrategy',
        strategy: novaStrategy.address,
        weight: 500n, // 5%
        is_nova: true
    });

    // 9. Final Fees Configuration (optional, default is 5%/5%/0.1%)
    console.log('Setting Fees (5% Admin, 5% Burn, 0.1% Withdraw)...');
    await vault.send(provider.sender(), { value: toNano('0.1') }, {
        $$type: 'SetFees',
        performance_fee: 500n,
        burn_fee: 500n,
        withdrawal_fee: 10n
    });

    console.log('Deployment Complete!');
    console.log('--- Summary ---');
    console.log('Vault:', vault.address.toString());
    console.log('Main Strategy:', mainStrategy.address.toString());
    console.log('NOVA Strategy:', novaStrategy.address.toString());
    console.log('Admin:', admin.toString());
}
