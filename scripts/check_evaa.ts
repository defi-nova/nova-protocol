import { Address, TonClient, Dictionary } from '@ton/ton';
import { getHttpEndpoint } from '@orbs-network/ton-access';

async function main() {
    console.log("🔍 EVAA Asset ID Checker");
    
    // 1. Initialize Client
    const endpoint = await getHttpEndpoint({ network: 'mainnet' });
    const client = new TonClient({ endpoint });
    
    // 2. EVAA Master Address (Mainnet)
    // Try to find a known address or prompt user.
    // Based on search, we couldn't find a definitive "official" address in the top results.
    // However, we can try to use a known one if we had it.
    // For now, we ask the user to input it or we use a placeholder that user can replace.
    
    // We can try to guess from the search result "0xb73..." which was wrong.
    // Let's rely on the user having the address or finding it via the script instructions.
    // But to be helpful, let's try to look up "evaa" in TON DNS if possible? 
    // Not easy in this script without extra setup.
    
    const evaaAddressStr = process.argv[2];
    if (!evaaAddressStr) {
        console.log("⚠️  Please provide EVAA Master Address as an argument.");
        console.log("   Usage: npx ts-node scripts/check_evaa.ts <ADDRESS>");
        return;
    }

    const evaaAddress = Address.parse(evaaAddressStr);
    console.log(`📡 Querying EVAA Master at: ${evaaAddress.toString()}`);

    // 3. Query get_assets_config
    try {
        const result = await client.runMethod(evaaAddress, 'get_assets_config');
        // The return type is usually a Cell (dictionary) or a List.
        // In EVAA v1, it returns a Cell (Dictionary).
        
        const dictCell = result.stack.readCell();
        const dict = Dictionary.load(Dictionary.Keys.BigUint(256), Dictionary.Values.Cell(), dictCell.beginParse());
        
        console.log("\n📋 Asset Configuration:");
        
        const keys = dict.keys();
        for (const key of keys) {
            const slice = dict.get(key);
            if (!slice) continue;
            
            // Parse Asset Config (Approximate layout based on common patterns)
            // Usually: oracle:Address, decimals:uint8, ...
            // Or: token_address:Address ...
            // We just want to identify TON.
            
            // Let's try to infer from the data.
            // If asset ID is 0, it's likely TON.
            // If asset ID is hash(...), we check.
            
            console.log(`\n🔹 Asset ID: ${key} (Hex: 0x${key.toString(16)})`);
            
            // Heuristic check
            if (key === 0n) {
                console.log("   ✅ Potential TON ID (0)");
            }
            
            // Try to parse slice content to see if we find an address
            try {
                // If it starts with an address?
                // slice.loadAddress()
                console.log(`   Data Bits: ${slice.bits.length}`);
            } catch (e) {
                // Ignore
            }
        }
        
    } catch (e) {
        console.error("❌ Error querying contract:", e);
    }
}

main();
