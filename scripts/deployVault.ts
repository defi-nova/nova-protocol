import { toNano, beginCell, Address, Dictionary } from '@ton/core';
import { sha256_sync } from '@ton/crypto';
import { Vault } from '../build/Vault/Vault_Vault';
import { Strategy } from '../build/Strategy/Strategy_Strategy';
import { NetworkProvider } from '@ton/blueprint';

// TEP-64 Helpers
const ONCHAIN_CONTENT_PREFIX = 0x01; // 0x01 for on-chain
const SNAKE_PREFIX = 0x00;

function buildTokenMetadata(data: { [key: string]: string | undefined }): any {
    const dict = Dictionary.empty(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell());
    
    // Hash keys using sha256 as per TEP-64
    const entries = Object.entries(data);
    for (const [key, value] of entries) {
        if (value) {
            const keyHash = BigInt('0x' + sha256_sync(key).toString('hex'));
            
            // Value is a cell with snake format
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
    const admin = Address.parse("0QAmLCXR3ikA0ohMg6R82E2NHESHtXjA299_HqIe_Wqr1aXi");
    const recovery = admin; // Using same admin as recovery for now

    // 1. Deploy Vault with nTON Metadata
    console.log('Generating nTON Metadata...');
    const content = buildTokenMetadata({
        name: "Nova TON",
        symbol: "nTON",
        description: "Yield-bearing TON token by Nova Aggregator",
        image: "https://nova-aggregator.com/logo.png", // Замените на реальную ссылку
        decimals: "9"
    });
    
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
    const stonfi_router = Address.parse("EQB3n9NWuHqhRM9PaPISTPoo6Y6Br8_s7U_8Y5is6FscBR8");
    const stonfi_pton = Address.parse("EQCM3B12QK1e4yZSf8GtBRT0aLMNyEsBc_DhVfRRtOEffLez");
    const dedust_factory = Address.parse("EQBfBWT7X2BHg9tXAxzhz2aKiNTU1tpt5NsiK0uSDW_YAJ67");
    const usdt_master = Address.parse("EQCxE6mUtQJKFnGfaROTKOt1lZbDiiX1kCixRv7Nw2Id_sDs");
    const dedust_vault = Address.parse("EQD5_S8Oq_uO0X2T2yY2_G0Z_Z_Z_Z_Z_Z_Z_Z_Z_Z_Z_Z_Z"); // Placeholder
    
    const strategy = provider.open(await Strategy.fromInit(
        vault.address, 
        admin, 
        stonfi_router,
        stonfi_pton,
        dedust_factory,
        usdt_master,
        dedust_vault
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
            dedust_vault: dedust_vault,
            stonfi_router: stonfi_router,
            stonfi_pton: stonfi_pton,
            usdt_master: usdt_master
        }
    );

    // 2.2 Set Strategy Mode (0 = STON.fi LP, 1 = DeDust LP)
    console.log('Setting Strategy Mode to STON.fi LP...');
    await strategy.send(
        provider.sender(),
        {
            value: toNano('0.05'),
        },
        {
            $$type: 'SetStrategyMode',
            mode: 0n // Start with STON.fi LP
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
            is_nova: false,
            strategy: strategy.address,
            weight: 10000n // 100%
        }
    );

    console.log('Done!');
}
