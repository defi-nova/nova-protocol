import { Address, toNano } from '@ton/core';
import { Vault } from '../build/Vault/Vault_Vault';
import { NetworkProvider } from '@ton/blueprint';

export async function run(provider: NetworkProvider) {
    // 1. ТВОИ РЕАЛЬНЫЕ АДРЕСА ИЗ КОНСОЛИ
    const vaultAddress = Address.parse("EQA-4xPUbpvjSK9QIXRmPg500JSsfkTeyTBlsajkfsrm7IOa");
    const strategyAddress = Address.parse("EQDjQiSNaoeNLwD2-RFn_Mr4zs_9qFpIDgxYZ2n3MvMiF10E");
    
    // 2. Открываем контракт Vault
    const vault = provider.open(Vault.fromAddress(vaultAddress));

    console.log("Регистрируем стратегию в Vault...");
    console.log("Vault:", vaultAddress.toString());
    console.log("Strategy:", strategyAddress.toString());

    // 3. Отправляем транзакцию AddStrategy
    await vault.send(
        provider.sender(),
        {
            value: toNano('0.1'), // 0.1 TON хватит для записи в Map
        },
        {
            $$type: 'AddStrategy',
            strategy: strategyAddress,
            weight: 10000n, // 100% веса
            is_nova: false
        }
    );

    console.log("Готово! Теперь Vault знает про Strategy.");
}