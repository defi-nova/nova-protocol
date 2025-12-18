import "./messages.tact";

message(0x999) MaintainHealth {
    // For future real strategy implementation to prevent liquidation
    target_health: Int;
}

contract Strategy {
    vault_address: Address;
    total_invested: Int as coins; // This tracks our "principal" sent to EVAA
    admin_address: Address;
    evaa_master: Address;
    
    // Health Factor Mock
    current_health: Int;

    // State for Profit Calculation
    last_reported_balance: Int as coins;
    current_evaa_balance: Int as coins;
    
    // Keeper Mining Logic
    keeper_balances: map<Address, Int>;
    last_harvest_time: map<Address, Int>;

    // Configuration
    ton_asset_id: Int; 

    receive(msg: SetAssetId) {
        require(context().sender == self.admin_address, "Only admin");
        self.ton_asset_id = msg.asset_id;
    }

    init(vault: Address, admin: Address, evaa_master: Address) {
        self.vault_address = vault;
        self.total_invested = 0;
        self.last_reported_balance = 0;
        self.current_evaa_balance = 0;
        self.admin_address = admin;
        self.evaa_master = evaa_master;
        self.current_health = 2000; // 2.0 * 1000 - Safe start
        
        // Placeholder for TON Asset ID in EVAA (usually hash of address or specific ID)
        self.ton_asset_id = 5979697966427382277430635252575298020583921833118053153835; // Example hash
    }

    receive(msg: EvaaUserScData) {
        // Parse Assets Dictionary from EVAA
        // We receive the map directly. Tact handles the dictionary loading.
        // Key: 256-bit Int (Asset ID)
        // Value: EvaaAssetData (Struct)
        
        let ton_data: EvaaAssetData? = msg.assets.get(self.ton_asset_id);
        
        if (ton_data != null) {
            let d: EvaaAssetData = ton_data!!;
            let supply: Int = d.balance;
            let borrow: Int = d.borrow;
            
            // Net Balance for Profit Calc
            self.current_evaa_balance = supply - borrow;
            
            // Update Health Factor
            // Simple HF calculation: Supply / Borrow (scaled)
            if (borrow > 0) {
                 self.current_health = (supply * 1000) / borrow;
            } else {
                 self.current_health = 10000; // Infinite health
            }
        }
    }

    receive() {
        // Accept generic TON (e.g. from EVAA withdrawal)
        let ctx: Context = context();
        if (ctx.sender == self.evaa_master) {
             // Forward to Vault
             send(SendParameters{
                 to: self.vault_address,
                 value: 0,
                 mode: SendRemainingValue,
                 body: StrategyRefund{ amount: ctx.value }.toCell()
             });
        }
    }

    receive(msg: MaintainHealth) {
         // require(context().sender == self.admin_address, "Only admin/keeper"); 
         // Permissionless but check health
         
         // In real logic, we would query EVAA for HF.
         // Here we assume self.current_health is updated via some oracle or callback mechanism.
         // For this MVP, we just check the mocked value.
         
         if (self.current_health < msg.target_health) {
             // Logic to deleverage
             // repay() or withdraw()
             // Bounty logic: send reward to sender
             let bounty: Int = ton("0.05");
             send(SendParameters{
                 to: context().sender,
                 value: bounty,
                 mode: SendIgnoreErrors + SendPayGasSeparately,
                 body: "Bounty".asComment()
             });
         } else {
             throw(101); // Health is fine, no action needed
         }
    }

    receive(msg: Invest) {
        require(context().sender == self.vault_address, "Only vault");
        // require(self.current_health > 1100, "Risk of liquidation"); // REMOVED to allow deposits
        self.total_invested = self.total_invested + msg.amount;
        self.last_reported_balance = self.last_reported_balance + msg.amount; // Update base
        
        // Supply to EVAA
        // TEP-74 transfer to EVAA Master? No, EVAA usually takes TON via Op codes.
        // For native TON supply to EVAA:
        // We send a message to EVAA Master with op::supply logic?
        // Actually EVAA usually works with Jettons or Special messages for TON.
        // Based on "EvaaSupply" struct we added:
        
        // Note: EVAA mainnet interface might differ. We use the one requested.
        // But usually for TON supply, we send a message with op=1 (Supply) to the Pool/Master.
        
        send(SendParameters{
            to: self.evaa_master,
            value: msg.amount, // Sending the TON
            mode: SendPayGasSeparately,
            bounce: true,
            body: beginCell()
                .storeUint(1, 32) // op::supply
                .storeUint(0, 64) // query_id
                .storeUint(0, 64) // Some extra fields usually required by EVAA? 
                // EVAA docs: Supply TON -> just transfer with correct payload?
                // Let's assume the payload from user input description:
                // .storeUint(0x1, 32)
                // .storeUint(query_id, 64)
                // ...
                // But wait, for native TON supply in EVAA, we usually just send TON with a specific comment or empty body if it's a dedicated wallet?
                // No, "EvaaMaster" handles it.
                // Let's stick to the generic "Supply" op code requested.
                .endCell()
        });
        
        // Confirm to unlock Vault
        send(SendParameters{
            to: self.vault_address,
            value: ton("0.01"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: "StrategyConfirmation".asComment()
        });
    }

    receive(msg: Divest) {
        require(context().sender == self.vault_address, "Only vault");
        // require(self.total_invested >= msg.amount, "Insufficient funds"); // We don't know real balance in EVAA easily without query
        
        // We track `total_invested` as principal.
        // We request withdraw from EVAA.
        
        send(SendParameters{
            to: self.evaa_master,
            value: ton("0.1"), // Gas for EVAA to process
            mode: SendPayGasSeparately,
            bounce: true,
            body: beginCell()
                .storeUint(2, 32) // op::withdraw
                .storeUint(0, 64)
                .storeCoins(msg.amount)
                .storeAddress(self.vault_address) // Redirect directly to Vault if supported? 
                // Usually EVAA returns to sender (Strategy).
                // If it returns to Strategy, Strategy needs to forward to Vault.
                // We'll assume Strategy receives it first.
                .endCell()
        });
        
        // We update our accounting assuming success (or wait for callback)
        // For MVP async, we optimistically reduce invested, but if it fails, we are out of sync.
        // Correct way: Wait for money to come back to `receive()`.
        // But Vault waits for "StrategyRefund".
    }

    // Handle refund from EVAA (simple TON transfer)
    receive("EvaaWithdrawSuccess") {
        // This is a mock handler for when EVAA sends money back.
        // In reality, it will be an empty body or comment transfer.
        // We need to forward this to Vault.
        let amount: Int = context().value;
        
        // We need to know if this is a divest or harvest or panic?
        // Vault is locked waiting for "StrategyRefund".
        
        send(SendParameters{
            to: self.vault_address,
            value: 0,
            mode: SendRemainingValue,
            bounce: false,
            body: StrategyRefund{ amount: amount }.toCell()
        });
        
        // Update accounting
        if (self.total_invested >= amount) {
            self.total_invested = self.total_invested - amount;
        } else {
            self.total_invested = 0;
        }
    }

    receive(msg: PanicWithdraw) {
        require(context().sender == self.vault_address, "Only vault");
        
        // Emergency exit: Withdraw ALL from EVAA
        // We don't know exact balance, but let's try to withdraw a huge amount or use "Max" flag if exists.
        // Or withdraw `total_invested`.
        
        send(SendParameters{
            to: self.evaa_master,
            value: ton("0.2"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: beginCell()
                .storeUint(2, 32) // Withdraw
                .storeUint(0, 64)
                .storeCoins(self.total_invested) // Try to get everything we know of
                .endCell()
        });
        
        // We rely on the receive() handler to forward funds to Vault.
        // But Vault expects "StrategyRefund" NOW?
        // No, Vault is locked. It waits.
    }

    receive(msg: Harvest) {
        // Permissionless Harvest with Bounty
        let ctx: Context = context();
        require(self.current_health > 1100, "Risk of liquidation");
        
        // 1. Time Lock (1 Hour)
        let last_time: Int? = self.last_harvest_time.get(ctx.sender);
        if (last_time != null) {
            require(now() > last_time!! + 3600, "Wait 1 hour!");
        }

        // Use REAL data from EVAA (updated via EvaaUserScData)
        // Fallback to invested amount if no data yet (start of lifecycle)
        let current_balance: Int = self.current_evaa_balance;
        if (current_balance == 0 && self.total_invested > 0) {
             current_balance = self.total_invested; 
        }

        let profit: Int = current_balance - self.last_reported_balance;
        require(profit >= msg.min_profit, "Slippage too high");

        // 2. Calculate Reward
        // "let reward = ctx.value + bonus"
        // Bonus is 20% of profit?
        // Let's assume bounty logic:
        let bonus: Int = (profit * 20) / 100;
        let reward: Int = ctx.value + bonus;
        
        // Accumulate reward in keeper_balances
        let old_balance: Int = 0;
        let existing: Int? = self.keeper_balances.get(ctx.sender);
        if (existing != null) {
            old_balance = existing!!;
        }
        self.keeper_balances.set(ctx.sender, old_balance + reward);
        
        // Update Time
        self.last_harvest_time.set(ctx.sender, now());

        // Report Profit to Vault (excluding bonus/bounty)
        // Note: The bonus is kept in the contract until claimed.
        // The profit reported to Vault should be net of what we "owe" the keeper.
        let real_profit: Int = profit - bonus;
        
        if (real_profit > 0) {
            // Send UpdatePPS to Vault
            // Vault expects the TOTAL value of assets in Strategy.
            // But we owe `bonus` to keeper. 
            // So actual assets belonging to Vault = current_balance - bonus.
            // Wait, we also owe `ctx.value` (gas refund) which is in `myBalance()` now.
            // PPS calculation is usually based on Net Asset Value (NAV).
            // NAV = Assets - Liabilities.
            // Liability = keeper_balances.
            // But simpler: just report `current_balance` minus `bonus`.
            // The `ctx.value` part is gas, effectively external money added to contract balance, then owed back.
            // So it shouldn't affect PPS.
            
            send(SendParameters{
                to: self.vault_address,
                value: 0,
                mode: SendRemainingValue,
                body: UpdatePPS{ new_assets_value: current_balance - bonus }.toCell()
            });
            
            // Update High Water Mark
            // We consider the bonus "paid" (liability created), so new base is current_balance.
            // Wait, if we deduct bonus from PPS, next time we shouldn't double count.
            // last_reported_balance should track what Vault "knows" about.
            // So last_reported_balance = current_balance - bonus.
            self.last_reported_balance = current_balance - bonus;
        }
    }

    receive(msg: ClaimReward) {
        let ctx: Context = context();
        let last_time: Int? = self.last_harvest_time.get(ctx.sender);
        require(last_time != null, "No harvest history");
        require(now() > last_time!! + 604800, "7 days not passed yet");

        let reward_amount: Int? = self.keeper_balances.get(ctx.sender);
        if (reward_amount != null && reward_amount!! > 0) {
            self.keeper_balances.set(ctx.sender, 0);
            send(SendParameters{
                to: ctx.sender,
                value: reward_amount!!,
                mode: SendIgnoreErrors, // Don't revert if fails, but balance is already 0? Risk.
                // Better: SendRemainingValue? No, specific amount.
                // We send `reward_amount`. Gas should be covered by `msg.value` of ClaimReward.
                // But `reward_amount` includes accumulated gas refunds.
                body: "Reward Claimed".asComment()
            });
        }
    }
    
    // Helper to simulate receiving profit from external source
    receive("SimulateProfit") {
         let ctx: Context = context();
         self.total_invested = self.total_invested + ctx.value;
         self.report();
    }

    fun report() {
        send(SendParameters{
            to: self.vault_address,
            value: ton("0.01"),
            mode: SendPayGasSeparately,
            bounce: false,
            body: UpdatePPS{
                new_assets_value: self.total_invested
            }.toCell()
        });
    }
    
    get fun balance(): Int {
        return self.total_invested;
    }

    get fun get_strategy_data(): StrategyData {
        return StrategyData{
            total_invested: self.total_invested,
            current_evaa_balance: self.current_evaa_balance,
            last_reported_balance: self.last_reported_balance
        };
    }

    get fun get_keeper_balance(keeper: Address): Int {
        let bal: Int? = self.keeper_balances.get(keeper);
        if (bal != null) {
            return bal!!;
        }
        return 0;
    }

    // Bounced Handler
    bounced(src: Slice) {
        // Handle bounced messages from EVAA
        // Check Op Code if possible, or just assume failure if from EVAA
        // Since we don't strictly check sender in bounced (it's from router?), we assume it's related to our calls.
        
        // 1. Supply Bounced (Op = 1)
        // If supply failed, money is returned.
        // We should refund Vault.
        
        let amount: Int = context().value; // Returned value
        
        // We need to decrement total_invested if we incremented it
        // But we can't easily distinguish Supply vs Withdraw bounce just by amount?
        // Use op code from src
        let op: Int = src.loadUint(32);
        
        if (op == 0xFFFFFFFF) {
            op = src.loadUint(32); // Original Op
        }
        
        if (op == 1) { // Supply failed
            // Revert investment accounting
             if (self.total_invested >= amount) {
                 self.total_invested = self.total_invested - amount;
             }
             
             // Refund Vault
             send(SendParameters{
                 to: self.vault_address,
                 value: 0,
                 mode: SendRemainingValue,
                 body: StrategyRefund{ amount: amount }.toCell()
             });
        } else if (op == 2) { // Withdraw failed
             // Notify Vault to unlock?
             // Vault is waiting for StrategyRefund.
             // We send StrategyRefund with 0 amount (or just gas) to unlock logic?
             // But if we send 0, Vault might think migration failed (amount=0).
             // Which is correct.
             
             send(SendParameters{
                 to: self.vault_address,
                 value: 0,
                 mode: SendRemainingValue,
                 body: StrategyRefund{ amount: 0 }.toCell()
             });
        }
    }
}

struct StrategyData {
    total_invested: Int;
    current_evaa_balance: Int;
    last_reported_balance: Int;
}
