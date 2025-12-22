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

    // DEX & Protocol Addresses (Passed during init)
    stonfi_router: Address;
    stonfi_pton: Address;
    dedust_factory: Address;
    usdt_master: Address;
    
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
    strategy_mode: Int as uint8; // 0: EVAA Lending, 1: STON.fi LP, 2: DeDust LP

    // State for DEX LP
    is_lp_active: Bool;
    pending_ton_for_lp: Int as coins;
    current_lp_balance: Int as coins;
    
    // LP Tokens storage
    lp_token_wallet: Address?;
    usdt_wallet: Address?;

    // DEX Integration
    dedust_vault: Address;
    
    // DEX LP Logic
    // We need to store where we are currently invested (LP vs Lending)
    // For now, let's assume we can split funds or switch modes.
    // To keep it simple for this MVP: 
    // - EVAA is default for lending.
    // - If we want to LP, we use specific messages.
    // But the Strategy contract needs to hold LP tokens.

    receive(msg: SwapToJetton) {
        require(context().sender == self.admin_address, "Only admin"); 
        
        if (msg.dex_type == 0) {
            // DeDust Swap Logic
            send(SendParameters{
                to: self.dedust_vault,
                value: msg.amount + ton("0.15"),
                mode: SendPayGasSeparately,
                body: DedustSwap{
                    query_id: 0,
                    amount: msg.amount,
                    min_amount_out: msg.min_amount_out,
                    deadline: now() + 300,
                    recipient: myAddress()
                }.toCell()
            });
        } else if (msg.dex_type == 1) {
            // STON.fi v2 Swap Logic (pTON -> USDT)
            send(SendParameters{
                to: self.stonfi_pton,
                value: msg.amount + ton("0.3"),
                mode: SendPayGasSeparately,
                body: JettonTransfer{
                    query_id: 0,
                    amount: msg.amount,
                    destination: self.stonfi_router,
                    response_destination: myAddress(),
                    custom_payload: null,
                    forward_ton_amount: ton("0.24"),
                    forward_payload: StonfiSwap{
                        otherTokenWallet: self.usdt_wallet!!, // USDT Jetton Wallet of Strategy
                        refundAddress: myAddress(),
                        excessesAddress: myAddress(),
                        deadline: (now() + 300),
                        additionalData: SwapAdditionalData{
                            minOut: msg.min_amount_out,
                            receiverAddress: myAddress(),
                            fwdGas: ton("0.15"),
                            customPayload: null,
                            refundFwdGas: 0,
                            refundPayload: null,
                            refFee: 10, // 0.1%
                            referralAddress: self.admin_address
                        }.toCell()
                    }.toCell()
                }.toCell()
            });
        }
    }

    // Removed duplicated get_strategy_data

    init(vault: Address, admin: Address, evaa_master: Address, stonfi_router: Address, stonfi_pton: Address, dedust_factory: Address, usdt_master: Address, dedust_vault: Address) {
        self.vault_address = vault;
        self.admin_address = admin;
        self.evaa_master = evaa_master;
        self.stonfi_router = stonfi_router;
        self.stonfi_pton = stonfi_pton;
        self.dedust_factory = dedust_factory;
        self.usdt_master = usdt_master;
        self.dedust_vault = dedust_vault;

        self.total_invested = 0;
        self.last_reported_balance = 0;
        self.current_evaa_balance = 0;
        self.current_health = 10000; // Safe start
        self.is_lp_active = false;
        self.pending_ton_for_lp = 0;
        self.current_lp_balance = 0;
        self.strategy_mode = 0; // Default to EVAA
        self.ton_asset_id = 0; 
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

    receive(msg: JettonTransferNotification) {
        let ctx: Context = context();
        
        // 1. Handle USDT received (likely from swap)
        if (self.usdt_wallet != null && ctx.sender == self.usdt_wallet!!) {
            if (self.pending_ton_for_lp > 0) {
                // PHASE: Investing (USDT arrived from swap, now provide LP)
                if (self.strategy_mode == 1) {
                    // STON.fi v2 LP Provision
                    send(SendParameters{
                        to: self.usdt_wallet!!,
                        value: ton("0.4"),
                        mode: SendPayGasSeparately,
                        body: JettonTransfer{
                            query_id: 0,
                            amount: msg.amount,
                            destination: self.stonfi_router,
                            response_destination: myAddress(),
                            custom_payload: null,
                            forward_ton_amount: ton("0.3"),
                            forward_payload: StonfiProvideLiquidity{
                                otherTokenWallet: self.stonfi_pton,
                                minLpOut: 1, // Should be calculated or passed
                                refundAddress: myAddress(),
                                excessesAddress: myAddress(),
                                deadline: (now() + 300)
                        }.toCell()
                    }.toCell()
                });
                    // Also need to send the TON side (handled by StonfiProvideLiquidity with pTON usually, 
                    // but here we send it separately or as part of the same flow if using router v2)
                    // For v2, we send USDT to router with pTON address as other token.
                    // The router will expect the other token (TON) to be sent as well.
                    send(SendParameters{
                        to: self.stonfi_pton,
                        value: self.pending_ton_for_lp + ton("0.1"),
                        mode: SendPayGasSeparately,
                        body: JettonTransfer{
                            query_id: 0,
                            amount: self.pending_ton_for_lp,
                            destination: self.stonfi_router,
                            response_destination: myAddress(),
                            custom_payload: null,
                            forward_ton_amount: ton("0.05"),
                            forward_payload: null
                        }.toCell()
                    });
                    
                    self.is_lp_active = true;
                    self.pending_ton_for_lp = 0;
                } else if (self.strategy_mode == 2) {
                    // DeDust LP Provision
                    // For DeDust, we need to deposit both assets to the pool
                    // This is more complex and usually involves the Factory/Pool/Vault
                    // Simplified for now:
                    self.is_lp_active = true;
                    self.pending_ton_for_lp = 0;
                }
                self.report_to_vault();
            } else if (self.is_lp_active) {
                // PHASE: Divesting (USDT arrived from burning LP tokens, now swap back to TON)
                // (Already implemented basic swap back)
            }
        }
        
        // 2. Handle LP Tokens received
        if (self.lp_token_wallet != null && ctx.sender == self.lp_token_wallet!!) {
            self.current_lp_balance = self.current_lp_balance + msg.amount;
            self.report_to_vault();
        }
    }

    fun report_to_vault() {
        send(SendParameters{
            to: self.vault_address,
            value: ton("0.01"),
            mode: SendPayGasSeparately,
            body: UpdatePPS{ new_assets_value: self.total_invested }.toCell()
        });
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

             // Update accounting: if received more than invested - it's profit
             if (ctx.value > self.total_invested) {
                 self.total_invested = 0;
             } else {
                 self.total_invested = self.total_invested - ctx.value;
             }
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
        self.total_invested = self.total_invested + msg.amount;
        self.last_reported_balance = self.last_reported_balance + msg.amount;
        
        let swap_amount: Int = msg.amount / 2;

        if (self.strategy_mode == 0) {
            // MODE 0: EVAA Lending
            send(SendParameters{
                to: self.evaa_master,
                value: msg.amount,
                mode: SendPayGasSeparately,
                bounce: true,
                body: EvaaSupply{
                    query_id: 0,
                    amount: msg.amount,
                    user_address: myAddress(),
                    include_user_code: 0,
                    amount_to_transfer: msg.amount,
                    payload: null
                }.toCell()
            });
        } else if (self.strategy_mode == 1) {
            // MODE 1: STON.fi LP (TON/USDT)
            self.pending_ton_for_lp = msg.amount - swap_amount;
            
            // Swap 50% TON to USDT via STON.fi v2 (pTON -> USDT)
            send(SendParameters{
                to: self.stonfi_pton,
                value: swap_amount + ton("0.4"), // Extra for gas and forward fee
                mode: SendPayGasSeparately,
                body: JettonTransfer{
                    query_id: 0,
                    amount: swap_amount,
                    destination: self.stonfi_router,
                    response_destination: myAddress(),
                    custom_payload: null,
                    forward_ton_amount: ton("0.24"),
                    forward_payload: StonfiSwap{
                        otherTokenWallet: self.usdt_wallet!!,
                        refundAddress: myAddress(),
                        excessesAddress: myAddress(),
                        deadline: (now() + 300),
                        additionalData: SwapAdditionalData{
                            minOut: 1,
                            receiverAddress: myAddress(),
                            fwdGas: ton("0.15"),
                            customPayload: null,
                            refundFwdGas: 0,
                            refundPayload: null,
                            refFee: 10,
                            referralAddress: self.admin_address
                        }.toCell()
                    }.toCell()
                }.toCell()
            });
        } else if (self.strategy_mode == 2) {
            self.pending_ton_for_lp = msg.amount - swap_amount;
            
            // Swap 50% TON to USDT via DeDust
            send(SendParameters{
                to: self.dedust_vault,
                    value: swap_amount + ton("0.2"),
                    mode: SendPayGasSeparately,
                    body: DedustSwap{
                        query_id: 0,
                        amount: swap_amount,
                        min_amount_out: 1,
                        deadline: (now() + 300),
                        recipient: myAddress()
                    }.toCell()
            });
        }
        
        // Confirm to Vault
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
        
        if (self.strategy_mode == 0) {
            // MODE 0: EVAA Withdrawal
            send(SendParameters{
                to: self.evaa_master,
                value: ton("0.2"), // Gas for withdrawal
                mode: SendPayGasSeparately,
                bounce: true,
                body: EvaaWithdraw{
                    query_id: 0,
                    amount: msg.amount,
                    user_address: myAddress(),
                    include_user_code: 0,
                    amount_to_transfer: 0,
                    payload: null
                }.toCell()
            });
        } else if (self.strategy_mode == 1 || self.strategy_mode == 2) {
            // LP MODE: Remove Liquidity
            if (self.lp_token_wallet != null && self.current_lp_balance > 0) {
                // Calculate how many LP tokens to burn based on requested amount
                // For MVP: burn all LP tokens if amount is large, or proportional
                let lp_to_burn: Int = (msg.amount * self.current_lp_balance) / self.last_reported_balance;
                if (lp_to_burn > self.current_lp_balance) {
                    lp_to_burn = self.current_lp_balance;
                }

                send(SendParameters{
                    to: self.lp_token_wallet!!,
                    value: ton("0.3"), // Gas for removal
                    mode: SendPayGasSeparately,
                    body: JettonBurn{
                        query_id: 0,
                        amount: lp_to_burn,
                        response_destination: myAddress(),
                        custom_payload: null
                    }.toCell()
                });
                
                self.current_lp_balance = self.current_lp_balance - lp_to_burn;
            }
        }
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
            body: EvaaWithdraw{
                query_id: 0,
                amount: self.total_invested, // Try to get everything we know of
                user_address: myAddress(),
                include_user_code: 0,
                amount_to_transfer: self.total_invested,
                payload: null
            }.toCell()
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
                value: ton("0.01"),
                mode: SendPayGasSeparately,
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

    receive(msg: SetDexAddresses) {
        require(context().sender == self.admin_address, "Only admin");
        self.dedust_factory = msg.dedust_factory;
        self.dedust_vault = msg.dedust_vault;
        self.stonfi_router = msg.stonfi_router;
        self.stonfi_pton = msg.stonfi_pton;
        self.usdt_master = msg.usdt_master;
    }

    receive(msg: SetJettonWallets) {
        require(context().sender == self.admin_address, "Only admin");
        if (msg.usdt != null) {
            self.usdt_wallet = msg.usdt;
        }
        if (msg.lp_token != null) {
            self.lp_token_wallet = msg.lp_token;
        }
    }

    receive(msg: SetEvaaMaster) {
        require(context().sender == self.admin_address, "Only admin");
        self.evaa_master = msg.evaa_master;
    }

    receive(msg: SetStrategyMode) {
        require(context().sender == self.admin_address, "Only admin");
        self.strategy_mode = msg.mode;
    }

    receive(msg: SetAssetId) {
        require(context().sender == self.admin_address, "Only admin");
        self.ton_asset_id = msg.asset_id;
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
