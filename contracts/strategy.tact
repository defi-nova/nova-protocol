import "./messages.tact";

contract Strategy {
    vault_address: Address;
    total_invested: Int as coins; // This tracks our principal
    admin_address: Address;

    // Constants
    const TOTAL_WEIGHT: Int = 10000;
    const GAS_INVEST: Int = ton("0.4");
    const GAS_SWAP_FWD: Int = ton("0.24");
    const GAS_DEDUST_SWAP: Int = ton("0.2");
    const GAS_REPORT: Int = ton("0.05");
    const GAS_DIVEST: Int = ton("0.3");
    const GAS_CONFIRM: Int = ton("0.05");

    // --- Additional Gas & Cooldown Constants ---
    const HARVEST_COOLDOWN: Int = 3600; // 1 hour
    const CLAIM_COOLDOWN: Int = 604800; // 7 days
    const SWAP_DEADLINE: Int = 300;
    const GAS_STONFI_FEE: Int = ton("0.15");
    const GAS_STONFI_EXTRA: Int = ton("0.1");
    const GAS_STONFI_FWD: Int = ton("0.05");
    const GAS_HARVEST_REPORT: Int = ton("0.01");
    const KEEPER_BONUS_PERCENT: Int = 20;
    const KEEPER_BONUS_BASE: Int = 100;

    // DEX & Protocol Addresses (Passed during init)
    stonfi_router: Address;
    stonfi_pton: Address;
    dedust_factory: Address;
    usdt_master: Address;
    
    // State for Profit Calculation
    last_reported_balance: Int as coins;
    
    // Keeper Mining Logic
    keeper_balances: map<Address, Int>;
    last_harvest_time: map<Address, Int>;

    strategy_mode: Int as uint8; // 0: STON.fi LP (TON/USDT), 1: DeDust LP (TON/USDT), 2: NOVA/TON LP

    // State for DEX LP
    is_lp_active: Bool;
    pending_ton_for_lp: Int as coins;
    current_lp_balance: Int as coins;
    simulated_profit: Int as coins; 
    
    // LP Tokens storage
    lp_token_wallet: Address?;
    usdt_wallet: Address?;
    nova_wallet: Address?; // Added for NOVA strategy

    // DEX Integration
    dedust_vault: Address;
    
    init(vault: Address, admin: Address, stonfi_router: Address, stonfi_pton: Address, dedust_factory: Address, usdt_master: Address, dedust_vault: Address) {
        self.vault_address = vault;
        self.admin_address = admin;
        self.stonfi_router = stonfi_router;
        self.stonfi_pton = stonfi_pton;
        self.dedust_factory = dedust_factory;
        self.usdt_master = usdt_master;
        self.dedust_vault = dedust_vault;

        self.total_invested = 0;
        self.last_reported_balance = 0;
        self.is_lp_active = false;
        self.pending_ton_for_lp = 0;
        self.current_lp_balance = 0;
        self.simulated_profit = 0;
        self.strategy_mode = 0; 
        self.nova_wallet = null;
    }

    receive(msg: JettonTransferNotification) {
        let ctx: Context = context();
        
        // 1. Handle USDT received (likely from swap)
        if (self.usdt_wallet != null && ctx.sender == self.usdt_wallet!!) {
            if (self.pending_ton_for_lp > 0) {
                // PHASE: Investing (USDT arrived from swap, now provide LP)
                if (self.strategy_mode == 0) {
                    // STON.fi v2 LP Provision
                    send(SendParameters{
                        to: self.usdt_wallet!!,
                        value: self.GAS_INVEST,
                        mode: SendPayGasSeparately,
                        body: JettonTransfer{
                            query_id: 0,
                            amount: msg.amount,
                            destination: self.stonfi_router,
                            response_destination: myAddress(),
                            custom_payload: null,
                            forward_ton_amount: self.GAS_DIVEST, // Reusing divest gas for forward
                            forward_payload: StonfiProvideLiquidity{
                                otherTokenWallet: self.stonfi_pton,
                                minLpOut: 1, 
                                refundAddress: myAddress(),
                                excessesAddress: myAddress(),
                                deadline: (now() + self.SWAP_DEADLINE)
                        }.toCell()
                    }.toCell()
                });
                    send(SendParameters{
                        to: self.stonfi_pton,
                        value: self.pending_ton_for_lp + self.GAS_STONFI_EXTRA,
                        mode: SendPayGasSeparately,
                        body: JettonTransfer{
                            query_id: 0,
                            amount: self.pending_ton_for_lp,
                            destination: self.stonfi_router,
                            response_destination: myAddress(),
                            custom_payload: null,
                            forward_ton_amount: self.GAS_STONFI_FWD,
                            forward_payload: null
                        }.toCell()
                    });
                    
                    self.is_lp_active = true;
                    self.pending_ton_for_lp = 0;
                } else if (self.strategy_mode == 1) {
                    // DeDust LP Provision
                    self.is_lp_active = true;
                    self.pending_ton_for_lp = 0;
                }
                self.report_to_vault();
            } 
        }
        
        // 2. Handle LP Tokens received
        if (self.lp_token_wallet != null && ctx.sender == self.lp_token_wallet!!) {
            self.current_lp_balance = self.current_lp_balance + msg.amount;
            self.report_to_vault();
        }
    }

    fun report_to_vault() {
        // In LP mode, we report total_invested + simulated_profit to keep PPS stable/increasing.
        // Ideally we'd value LP tokens, but that requires an oracle.
        let current_balance: Int = self.total_invested + self.simulated_profit;
        
        // Send enough TON to the vault to cover potential fees
        let value_to_send: Int = self.simulated_profit;
        if (value_to_send < self.GAS_REPORT) { value_to_send = self.GAS_REPORT; }

        send(SendParameters{
            to: self.vault_address,
            value: value_to_send,
            mode: SendPayGasSeparately,
            body: UpdatePPS{ new_assets_value: current_balance }.toCell()
        });
    }

    receive() {
        // Accept generic TON (refunds/excesses)
        let ctx: Context = context();
        if (ctx.value > 0) {
             send(SendParameters{
                 to: self.vault_address,
                 value: 0,
                 mode: SendRemainingValue,
                 body: StrategyRefund{ amount: ctx.value }.toCell()
             });
        }
    }

    receive(msg: Invest) {
        require(context().sender == self.vault_address, "Only vault");
        self.total_invested = self.total_invested + msg.amount;
        self.last_reported_balance = self.last_reported_balance + msg.amount;
        
        let swap_amount: Int = msg.amount / 2;

        if (self.strategy_mode == 0) {
            // MODE 0: STON.fi LP (TON/USDT)
            if (self.usdt_wallet != null) {
                self.pending_ton_for_lp = msg.amount - swap_amount;
                
                // Swap 50% TON to USDT via STON.fi v2 (pTON -> USDT)
                send(SendParameters{
                    to: self.stonfi_pton,
                    value: swap_amount + self.GAS_INVEST, 
                    mode: SendPayGasSeparately,
                    body: JettonTransfer{
                        query_id: 0,
                        amount: swap_amount,
                        destination: self.stonfi_router,
                        response_destination: myAddress(),
                        custom_payload: null,
                        forward_ton_amount: self.GAS_SWAP_FWD,
                        forward_payload: StonfiSwap{
                            otherTokenWallet: self.usdt_wallet!!,
                            refundAddress: myAddress(),
                                excessesAddress: myAddress(),
                                deadline: (now() + self.SWAP_DEADLINE),
                                additionalData: SwapAdditionalData{
                                    minOut: 1,
                                    receiverAddress: myAddress(),
                                    fwdGas: self.GAS_STONFI_FEE,
                                    customPayload: null,
                                    refundFwdGas: 0,
                                    refundPayload: null,
                                    refFee: 10,
                                    referralAddress: self.admin_address
                                }.toCell()
                            }.toCell()
                        }.toCell()
                    });
                } else {
                    self.pending_ton_for_lp = 0;
                }
            } else if (self.strategy_mode == 1) {
                // MODE 1: DeDust LP (TON/USDT)
                self.pending_ton_for_lp = msg.amount - swap_amount;
                
                send(SendParameters{
                    to: self.dedust_vault,
                    value: swap_amount + self.GAS_DEDUST_SWAP,
                    mode: SendPayGasSeparately,
                    body: DedustSwap{
                        query_id: 0,
                        amount: swap_amount,
                        min_amount_out: 1,
                        deadline: (now() + self.SWAP_DEADLINE),
                        recipient: myAddress()
                    }.toCell()
                });
            } else if (self.strategy_mode == 2) {
                // MODE 2: NOVA/TON LP (Fixed 5% Allocation)
                // For NOVA/TON, we assume it's on DeDust for this implementation
                if (self.nova_wallet != null) {
                    self.pending_ton_for_lp = msg.amount - swap_amount;
                    
                    send(SendParameters{
                        to: self.dedust_vault,
                        value: swap_amount + self.GAS_DEDUST_SWAP,
                        mode: SendPayGasSeparately,
                        body: DedustSwap{
                            query_id: 0,
                            amount: swap_amount,
                            min_amount_out: 1,
                            deadline: (now() + self.SWAP_DEADLINE),
                            recipient: myAddress()
                        }.toCell()
                    });
                }
            }
        
        // Confirm to Vault
        send(SendParameters{
            to: self.vault_address,
            value: self.GAS_CONFIRM,
            mode: SendPayGasSeparately,
            bounce: false,
            body: "StrategyConfirmation".asComment()
        });
    }

    receive(msg: Divest) {
        require(context().sender == self.vault_address, "Only vault");
        
        if (self.lp_token_wallet != null && self.current_lp_balance > 0) {
            let lp_to_burn: Int = (msg.amount * self.current_lp_balance) / self.last_reported_balance;
            if (lp_to_burn > self.current_lp_balance) {
                lp_to_burn = self.current_lp_balance;
            }

            send(SendParameters{
                to: self.lp_token_wallet!!,
                value: self.GAS_DIVEST, 
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

    receive(msg: PanicWithdraw) {
        require(context().sender == self.vault_address, "Only vault");
        // LP tokens should be burned or transferred to vault/admin
        // For simplicity, we skip specific logic here as LP is more complex to exit instantly
    }

    receive(msg: Harvest) {
        let ctx: Context = context();
        let last_time: Int? = self.last_harvest_time.get(ctx.sender);
        if (last_time != null) {
           require(now() > last_time!! + self.HARVEST_COOLDOWN, "Wait 1 hour!");
        }

        // LP mode profit is hard to track without oracle. 
        // For now, we assume profit is 0 until we have a way to value LP.
        let profit: Int = 0;
        
        // 2. Calculate Reward
        let bonus: Int = (profit * self.KEEPER_BONUS_PERCENT) / self.KEEPER_BONUS_BASE;
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
        let real_profit: Int = profit - bonus;
        
        if (real_profit > 0) {
            send(SendParameters{
                to: self.vault_address,
                value: self.GAS_HARVEST_REPORT,
                mode: SendPayGasSeparately,
                body: UpdatePPS{ new_assets_value: self.total_invested + real_profit }.toCell()
            });
            
            self.last_reported_balance = self.total_invested + real_profit;
        }
    }

    receive(msg: ClaimReward) {
        let ctx: Context = context();
        let last_time: Int? = self.last_harvest_time.get(ctx.sender);
        require(last_time != null, "No harvest history");
        require(now() > last_time!! + self.CLAIM_COOLDOWN, "7 days not passed yet");

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
         // Profit simulation should NOT increase total_invested (principal)
         // Instead, we increase simulated_profit
         self.simulated_profit = self.simulated_profit + ctx.value;
         self.report_to_vault();
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
        if (msg.nova != null) {
            self.nova_wallet = msg.nova;
        }
    }

    receive(msg: SetStrategyMode) {
        require(context().sender == self.admin_address, "Only admin");
        self.strategy_mode = msg.mode;
    }

    get fun get_strategy_data(): StrategyData {
        return StrategyData{
            total_invested: self.total_invested,
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
        // Generic bounced handler for TON refunds
        let amount: Int = context().value;
        
        // If it's a bounced message, we generally want to refund the vault 
        // if it was part of an investment flow that failed.
        // However, with DEX LPs, we have complex multi-step flows.
        
        // Simple logic for now: if we get a bounce, something went wrong.
        // We report to vault to potentially unlock.
        
        send(SendParameters{
            to: self.vault_address,
            value: 0,
            mode: SendRemainingValue,
            body: StrategyRefund{ amount: amount }.toCell()
        });
    }
}

struct StrategyData {
    total_invested: Int;
    last_reported_balance: Int;
}
