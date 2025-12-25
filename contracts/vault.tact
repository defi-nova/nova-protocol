import "./messages.tact";
import "./jetton_wallet.tact";

struct StrategyParams {
    weight: Int as uint16; // Basis points (10000 = 100%)
    balance: Int as coins;
    active: Bool;
    current_apy: Int as uint16; // В базисных пунктах (например, 1500 = 15%)
    is_nova: Bool;
}

contract Vault {
    
    const gasConsumption: Int = ton("0.02"); // Reduced for tests
    const PPS_PRECISION: Int = 1000000000000; // 10^12

    // --- Additional Gas & Threshold Constants ---
    const GAS_REBALANCE: Int = ton("0.35");
    const GAS_INVEST_MSG: Int = ton("0.05");
    const GAS_WITHDRAWAL: Int = ton("0.05");
    const GAS_MINT: Int = ton("0.05");
    const GAS_DIVEST_MIGRATE: Int = ton("0.1");
    const GAS_PANIC: Int = ton("0.25");
    const REBALANCE_THRESHOLD: Int = ton("0.1");
    const MIN_WITHDRAWAL: Int = ton("0.01");
    const SWAP_DEADLINE: Int = 300;
    const PROFIT_LIMIT_PERCENT: Int = 120;
    const PROFIT_LIMIT_BASE: Int = 100;

    total_shares: Int as coins;
    admin_address: Address;
    recovery_address: Address; // Admin Recovery
    locked_assets: Int as coins; // Assets currently being moved/locked
    
    // Multi-Strategy Storage
    strategies: map<Int, Address>; // ID -> Address
    strategy_info: map<Address, StrategyParams>; // Address -> Info
    strategies_count: Int;

    // Message from users (Run Node in Mini App)
    receive(msg: RunNode) {
        // Any user can click "Run Node" to trigger rebalancing
        // This is safe because it uses APY data previously set by the Admin
        self.optimize_and_rebalance();
        
        // Return remaining gas to the user
        self.reply("Node execution successful".asComment());
    }

    // Admin message to update APY data for multiple strategies at once
    receive(msg: BatchUpdateApy) {
        require(sender() == self.admin_address, "Only admin can update APY data");
        
        let i: Int = 0;
        while (i < self.strategies_count) {
            let entry: StrategyApy? = msg.apys.get(i);
            if (entry != null) {
                let info: StrategyParams? = self.strategy_info.get(entry!!.address);
                if (info != null) {
                    let updated: StrategyParams = info!!;
                    updated.current_apy = entry!!.apy;
                    self.strategy_info.set(entry!!.address, updated);
                }
            }
            i += 1;
        }
        
        // Automatically optimize weights after admin updates data
        self.optimize_and_rebalance();
    }

    // --- Constants for weight calculation ---
    const NOVA_WEIGHT: Int = 500; // Fixed 5% (500/10000)
    const MAX_SINGLE_PROTOCOL_WEIGHT: Int = 6000; // 60%
    const TOTAL_WEIGHT: Int = 10000; // 100%
    const REMAINING_WEIGHT: Int = 9500; // 95% (after NOVA)

    fun optimize_and_rebalance() {
        let total_apy: Int = 0;
        let active_strategies: Int = 0;
        
        // 1. Calculate total APY (excluding NOVA strategy from dynamic distribution)
        let i: Int = 0;
        while (i < self.strategies_count) {
            let addr: Address? = self.strategies.get(i);
            if (addr != null) {
                let info: StrategyParams? = self.strategy_info.get(addr!!);
                if (info != null && info!!.active && !info!!.is_nova) {
                    total_apy += info!!.current_apy;
                    active_strategies += 1;
                }
            }
            i += 1;
        }

        // 2. Distribute weights: NOVA gets fixed %, others share remaining proportional to APY
        i = 0;
        while (i < self.strategies_count) {
            let addr: Address? = self.strategies.get(i);
            if (addr != null) {
                let info: StrategyParams? = self.strategy_info.get(addr!!);
                if (info != null && info!!.active) {
                    let new_weight: Int = 0;
                    
                    if (info!!.is_nova) {
                        new_weight = self.NOVA_WEIGHT; 
                    } else if (total_apy > 0) {
                        new_weight = (info!!.current_apy * self.REMAINING_WEIGHT) / total_apy; 
                        // Safety check
                        if (new_weight > self.MAX_SINGLE_PROTOCOL_WEIGHT) { new_weight = self.MAX_SINGLE_PROTOCOL_WEIGHT; }
                    }
                    
                    let updated: StrategyParams = info!!;
                    updated.weight = new_weight;
                    self.strategy_info.set(addr!!, updated);
                }
            }
            i += 1;
        }
        
        // 3. Trigger rebalancing
        self.rebalance();
    }

    fun rebalance() {
        let i: Int = 0;
        
        while (i < self.strategies_count) {
            let addr: Address? = self.strategies.get(i);
            if (addr != null) {
                let info: StrategyParams? = self.strategy_info.get(addr!!);
                if (info != null && info!!.active) {
                    let target_balance: Int = (self.total_assets * info!!.weight) / self.TOTAL_WEIGHT;
                    let current_balance: Int = info!!.balance;
                    
                    if (current_balance > target_balance + self.REBALANCE_THRESHOLD) {
                        // Excess - withdraw from strategy
                        let to_withdraw: Int = current_balance - target_balance;
                        send(SendParameters{
                            to: addr!!,
                            value: self.GAS_REBALANCE,
                            mode: SendPayGasSeparately,
                            body: Divest{ amount: to_withdraw }.toCell()
                        });
                    } else if (current_balance < target_balance - self.REBALANCE_THRESHOLD && self.stored_balance > self.REBALANCE_THRESHOLD) {
                        // Deficit - invest idle funds
                        let to_invest: Int = target_balance - current_balance;
                        if (to_invest > self.stored_balance) { to_invest = self.stored_balance; }
                        
                        if (to_invest > 0) {
                            send(SendParameters{
                                to: addr!!,
                                value: to_invest + self.GAS_REBALANCE,
                                mode: SendPayGasSeparately,
                                body: Invest{ amount: to_invest }.toCell()
                            });
                            self.stored_balance -= to_invest;
                        }
                    }
                }
            }
            i += 1;
        }
    }

    // Admin message to update APY data manually
    receive(msg: UpdateProtocolApy) {
        require(sender() == self.admin_address, "Only admin");
        
        let info: StrategyParams? = self.strategy_info.get(msg.strategy);
        if (info != null) {
            let updated: StrategyParams = info!!;
            updated.current_apy = msg.apy;
            self.strategy_info.set(msg.strategy, updated);
            self.optimize_and_rebalance();
        }
    }

    receive("OptimizeWeights") {
        require(sender() == self.admin_address, "Only admin");
        self.optimize_and_rebalance();
    }

    total_strategy_balance: Int as coins; // Aggregated balance
    stored_balance: Int as coins; // Internal balance tracking for PPS security
    total_assets: Int as coins; // Total assets for accurate PPS calculation
    pending_withdrawals_total: Int as coins; // Total amount in withdrawal queue

    // Withdrawal Queue
    // We use a mapping with integer keys to simulate a queue
    // key: index, value: PendingWithdrawal
    withdrawal_queue: map<Int, PendingWithdrawal>;
    queue_head: Int;
    queue_tail: Int;

    // Jetton Params
    content: Cell;
    mintable: Bool;

    // --- Getters ---

    // Status Flags
    
    
    is_paused: Bool;

    // TIMELOCK LOGIC
    timelock_delay: Int; // Seconds
    pending_actions: map<Int, TimelockAction>;
    last_action_id: Int;

    // Default Fees & Constants
    const DEFAULT_PERFORMANCE_FEE: Int = 500; // 5%
    const DEFAULT_BURN_FEE: Int = 500;        // 5%
    const DEFAULT_WITHDRAWAL_FEE: Int = 10;   // 0.1%
    const DEFAULT_TIMELOCK: Int = 86400;      // 24 hours
    const BURN_ADDRESS: Address = address("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c");

    // Migration State
    migration_target: Address?;
    migration_amount: Int?;

    // Fee Configuration
    performance_fee: Int as uint16; // Basis points (500 = 5%)
    burn_fee: Int as uint16;        // Basis points (500 = 5%)
    withdrawal_fee: Int as uint16;  // Basis points (10 = 0.1%)
    
    // NOVA Token for burning
    nova_master: Address?;
    nova_vault: Address?; // DEX Vault to swap TON -> NOVA for burning

    init(admin: Address, recovery: Address, content: Cell) {
        self.total_shares = 0;
        self.admin_address = admin;
        self.recovery_address = recovery;
        self.locked_assets = 0;
        self.content = content;
        self.mintable = true;
        
        self.is_paused = false;
        self.migration_target = null;
        self.migration_amount = null;
        
        self.queue_head = 0;
        self.queue_tail = 0;
        
        // Initialize multi-strategy storage
        self.strategies = emptyMap();
        self.strategy_info = emptyMap();
        self.strategies_count = 0;
        self.total_strategy_balance = 0;
        self.stored_balance = 0;
        self.total_assets = 0; 
        self.pending_withdrawals_total = 0;
        self.timelock_delay = self.DEFAULT_TIMELOCK; 
        self.last_action_id = 0;

        // Default Fees
        self.performance_fee = self.DEFAULT_PERFORMANCE_FEE;
        self.burn_fee = self.DEFAULT_BURN_FEE;
        self.withdrawal_fee = self.DEFAULT_WITHDRAWAL_FEE;
        self.nova_master = null;
        self.nova_vault = null;
    }

    receive(msg: SetFees) {
        require(sender() == self.admin_address, "Only admin");
        self.performance_fee = msg.performance_fee;
        self.burn_fee = msg.burn_fee;
        self.withdrawal_fee = msg.withdrawal_fee;
    }

    receive(msg: SetNovaToken) {
        require(sender() == self.admin_address, "Only admin");
        self.nova_master = msg.nova_master;
        self.nova_vault = msg.nova_vault;
    }

    receive() {
        // Only owner can top up stored_balance via plain transfer
        // This is used for adding liquidity or donating to the vault
        if (sender() == self.admin_address) {
            self.stored_balance += context().value;
            self.total_assets += context().value;
        }
    }

    // --- User Interactions ---

    /**
     * @notice Deposit TON to mint shares
     * @param msg Deposit message containing amount and min_shares
     */
    receive(msg: Deposit) {
        let ctx: Context = context();
        
        // Check if deposits are paused
        if (self.is_paused) { throw(9780); }
        
        // Check for zero deposit amount
        require(msg.amount > 0, "Deposit amount must be greater than 0");
        
        // Use total_assets for accurate calculations (excludes gas reserves)
        let deposit_amount: Int = msg.amount; 
        let total_assets_before: Int = self.total_assets;
        let shares_to_mint: Int = 0;

        if (self.total_shares == 0) {
            // First deposit - 1:1 ratio
            shares_to_mint = deposit_amount;
        } else if (total_assets_before > 0) {
            // For subsequent deposits, use PPS to calculate shares
            // shares = amount * total_shares / total_assets
            shares_to_mint = (deposit_amount * self.total_shares) / total_assets_before;
            
            // Ensure at least 1 share for valid deposits
            if (shares_to_mint == 0 && deposit_amount > 0) {
                shares_to_mint = 1;
            }
        } else {
            // Edge case: no assets, treat as first deposit
            shares_to_mint = deposit_amount;
        }

        // Only validate for non-zero deposits
        if (deposit_amount > 0) {
            require(shares_to_mint > 0, "Shares calculation error");
        }

        // Update total assets with new deposit
        self.total_assets += deposit_amount;
        self.stored_balance += deposit_amount; // Track idle TON in contract

        // Mint Shares
        self.mint(ctx.sender, shares_to_mint);

        // Lock and Transfer to Strategy
        self.locked_assets = deposit_amount;
        
        // Invest in strategies based on allocation
        let remaining: Int = deposit_amount;
        let successful_invest: Int = 0;
        
        // Iterate through strategies
        let i: Int = 0;
        
        while (i < self.strategies_count && remaining > 0) {
             let strat_addr: Address? = self.strategies.get(i);
             if (strat_addr != null) {
                 let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                 if (info != null && info!!.active && info!!.weight > 0) {
                      // Calculate amount
                      let invest_amount: Int = (deposit_amount * info!!.weight) / self.TOTAL_WEIGHT;
                      if (invest_amount > remaining) { invest_amount = remaining; }
                      
                      if (invest_amount > 0) {
                          // Send Invest message
                          send(SendParameters{
                              to: strat_addr!!,
                              value: invest_amount + self.GAS_INVEST_MSG, 
                              mode: SendPayGasSeparately + SendIgnoreErrors,
                              bounce: true,
                              body: Invest{
                                  amount: invest_amount
                              }.toCell()
                          });
                          
                          remaining = remaining - invest_amount;
                          successful_invest = successful_invest + invest_amount;
                          self.stored_balance = self.stored_balance - invest_amount; // Decrease idle balance when invested
                          
                          // Update Strategy Balance optimistically
                          self.strategy_info.set(strat_addr!!, StrategyParams{
                              active: info!!.active,
                              weight: info!!.weight,
                              balance: info!!.balance + invest_amount,
                              current_apy: info!!.current_apy,
                              is_nova: info!!.is_nova
                          });
                          self.total_strategy_balance += invest_amount;
                      }
                 }
             }
             i = i + 1;
        }
        
        // Update locked_assets to reflect what we attempted to invest
        self.locked_assets = successful_invest;
    }

    /**
     * @notice Handle Jetton Burn (Withdrawal request)
     * @dev Checks liquidity and either pays immediately or queues withdrawal
     */
    receive(msg: JettonBurnNotification) {
        let ctx: Context = context();
        self._requireWallet(ctx.sender, msg.sender); // Validate sender is correct wallet
        
        let shares_burned: Int = msg.amount;
        
        // Calculate withdrawal amount: (shares * total_assets) / total_shares
        let gross_withdraw_amount: Int = 0;
        if (self.total_shares > 0 && self.total_assets > 0) {
            gross_withdraw_amount = (shares_burned * self.total_assets) / self.total_shares;
        }
        
        // Apply Withdrawal Fee
        let withdrawal_fee_amount: Int = (gross_withdraw_amount * self.withdrawal_fee) / self.TOTAL_WEIGHT;
        let withdraw_amount: Int = gross_withdraw_amount - withdrawal_fee_amount;

        // Ensure minimum withdrawal
        if (withdraw_amount <= 0) {
            withdraw_amount = self.MIN_WITHDRAWAL;
        }
        
        // Update contract state
        self.total_shares = self.total_shares - shares_burned;
        self.total_assets = self.total_assets - gross_withdraw_amount;
        
        // Check available liquidity using stored_balance (idle funds)
        let available_liquidity: Int = self.stored_balance;
        
        if (available_liquidity >= withdraw_amount && myBalance() > withdraw_amount + self.GAS_WITHDRAWAL) {
            // Pay directly from stored_balance
            self.stored_balance = self.stored_balance - gross_withdraw_amount;
            
            send(SendParameters{
                to: msg.response_destination,
                value: withdraw_amount,
                mode: SendPayGasSeparately,
                bounce: false,
                body: "Withdrawal successful".asComment()
            });

            // Send fee to admin if exists
            if (withdrawal_fee_amount > 0) {
                send(SendParameters{
                    to: self.admin_address,
                    value: withdrawal_fee_amount,
                    mode: SendPayGasSeparately | SendIgnoreErrors,
                    body: "Withdrawal Fee".asComment()
                });
            }
        } else {
            // Need to divest from strategy - add to queue and send request
            let needed: Int = withdraw_amount - available_liquidity;
            if (needed < 0) { needed = 0; }
            
            // Add to withdrawal queue
            self.withdrawal_queue.set(self.queue_tail, PendingWithdrawal{
                user: msg.response_destination,
                amount: withdraw_amount,
                gross_amount: gross_withdraw_amount
            });
            self.queue_tail = self.queue_tail + 1;
            self.pending_withdrawals_total = self.pending_withdrawals_total + gross_withdraw_amount;
            
            // Find first active strategy and send divest request
            let strat_addr: Address? = self.strategies.get(0); // For simplicity, use first strategy
            if (strat_addr != null) {
                send(SendParameters{
                    to: strat_addr!!,
                    value: 0,
                    mode: SendRemainingValue,
                    bounce: false,
                    body: Divest{ amount: needed + self.GAS_WITHDRAWAL }.toCell()
                });
            }
        }
    }

    // --- Strategy Interactions ---

    receive(msg: UpdatePPS) {
        let sender: Address = context().sender;
        let info: StrategyParams? = self.strategy_info.get(sender);
        require(info != null, "Unknown strategy");
        require(info!!.active, "Strategy not active");
        
        let old_bal: Int = info!!.balance;
        let new_bal: Int = msg.new_assets_value;
        
        // Performance Fee & Burning Logic
        if (new_bal > old_bal) {
            let profit: Int = new_bal - old_bal;
            
            // 1. Admin Fee
            let admin_fee_amount: Int = (profit * self.performance_fee) / self.TOTAL_WEIGHT;
            if (admin_fee_amount > 0) {
                send(SendParameters{
                    to: self.admin_address,
                    value: admin_fee_amount,
                    mode: SendPayGasSeparately | SendIgnoreErrors,
                    body: "Performance Fee (Admin)".asComment()
                });
                new_bal = new_bal - admin_fee_amount;
                // Note: stored_balance doesn't change here because profit is still in the strategy
            }
 
            // 2. Burning Fee (TON -> NOVA)
            let burn_fee_amount: Int = (profit * self.burn_fee) / self.TOTAL_WEIGHT;
            if (burn_fee_amount > 0 && self.nova_vault != null) {
                // Swap TON to NOVA via DEX for burning
                send(SendParameters{
                    to: self.nova_vault!!,
                    value: burn_fee_amount,
                    mode: SendPayGasSeparately | SendIgnoreErrors,
                    body: DedustSwap{
                        query_id: 0,
                        amount: burn_fee_amount,
                        min_amount_out: 1,
                        deadline: (now() + self.SWAP_DEADLINE),
                        recipient: self.BURN_ADDRESS
                    }.toCell()
                });
                new_bal = new_bal - burn_fee_amount;
                // Note: stored_balance doesn't change here because profit is still in the strategy
            }
        }

        // Security Check: Max 20% profit jump (after fees)
        if (old_bal > 0) {
            let limit: Int = (old_bal * self.PROFIT_LIMIT_PERCENT) / self.PROFIT_LIMIT_BASE;
            if (new_bal > limit) {
                throw(9086);
            }
        }
        
        // Update Info
        self.strategy_info.set(sender, StrategyParams{
            active: true,
            weight: info!!.weight,
            balance: new_bal,
            current_apy: info!!.current_apy,
            is_nova: info!!.is_nova
        });
        
        // Update Total
        self.total_strategy_balance = self.total_strategy_balance - old_bal + new_bal;
        
        // Update total_assets to reflect strategy balance changes
        self.total_assets = self.stored_balance + self.total_strategy_balance - self.pending_withdrawals_total;
    }

    receive("StrategyConfirmation") {
        let sender: Address = context().sender;
        let info: StrategyParams? = self.strategy_info.get(sender);
        require(info != null, "Unknown strategy");
        
         
        
        // We rely on optimistic updates during Invest, so locked_assets should be 0 (or close to 0)
        // If we want to be safe, we can ensure it doesn't go negative?
        // But for now, we just acknowledge.
    }

    receive(msg: StrategyRefund) {
        // Security Fix: Verify sender is a known strategy
        let info: StrategyParams? = self.strategy_info.get(context().sender);
        require(info != null, "Security Alert: Unknown strategy sender");
        
        // Update stored_balance
        self.stored_balance = self.stored_balance + msg.amount;
        
        // Update strategy balance
        let old_bal: Int = info!!.balance;
        let new_bal: Int = old_bal - msg.amount;
        if (new_bal < 0) { new_bal = 0; }
        
        self.strategy_info.set(context().sender, StrategyParams{
            active: info!!.active,
            weight: info!!.weight,
            balance: new_bal,
            current_apy: info!!.current_apy,
            is_nova: info!!.is_nova
        });
        
        // Update total_strategy_balance
        self.total_strategy_balance = self.total_strategy_balance - old_bal + new_bal;
        
        // Update total_assets
        self.total_assets = self.stored_balance + self.total_strategy_balance - self.pending_withdrawals_total;
        
        // MIGRATION LOGIC
        if (self.migration_target != null) {
            // Check if this refund is from the old strategy?
            // We assume if migration is active, any refund is part of it?
            // This is complex. For now, let's assume refund is from old strategy.
            let target: Address? = self.migration_target;
            if (target != null) {
                let targetInfo: StrategyParams? = self.strategy_info.get(target!!);
                if (targetInfo != null) {
                     self.strategy_info.set(target!!, StrategyParams{
                          active: targetInfo!!.active,
                          weight: targetInfo!!.weight,
                          balance: targetInfo!!.balance + msg.amount,
                          current_apy: targetInfo!!.current_apy,
                          is_nova: targetInfo!!.is_nova
                     });
                     self.total_strategy_balance = self.total_strategy_balance + msg.amount;
                     
                     // Send Invest to New Strategy
                     send(SendParameters{
                        to: target!!,
                        value: msg.amount + self.GAS_INVEST_MSG, 
                        mode: SendPayGasSeparately, 
                        bounce: true,
                        body: Invest{
                            amount: msg.amount
                        }.toCell()
                     });
                     self.stored_balance = self.stored_balance - msg.amount;
                 }
            }
            
            // Clear Migration State
            self.migration_target = null;
            self.migration_amount = null;
        } else {
            // Process Withdrawal Queue when funds arrive
            self.processWithdrawals(50);
        }
    }

    fun processWithdrawals(limit: Int) {
        let available: Int = self.stored_balance; 
        if (available < 0) { available = 0; }
        
        let count: Int = 0;
        
        while (self.queue_head < self.queue_tail && available > 0 && count < limit) {
            let req: PendingWithdrawal = self.withdrawal_queue.get(self.queue_head)!!;
            
            if (available >= req.gross_amount) {
                // Pay user
                send(SendParameters{
                    to: req.user,
                    value: req.amount,
                    mode: SendPayGasSeparately, 
                    bounce: false,
                    body: "Withdrawal".asComment()
                });

                // Pay fee to admin
                let fee: Int = req.gross_amount - req.amount;
                if (fee > 0) {
                    send(SendParameters{
                        to: self.admin_address,
                        value: fee,
                        mode: SendPayGasSeparately | SendIgnoreErrors,
                        body: "Withdrawal Fee".asComment()
                    });
                }

                self.stored_balance = self.stored_balance - req.gross_amount;
                self.pending_withdrawals_total = self.pending_withdrawals_total - req.gross_amount;
                
                available = available - req.gross_amount;
                self.withdrawal_queue.set(self.queue_head, null); // Clear
                self.queue_head = self.queue_head + 1;
                count = count + 1;
            } else {
                available = 0; // Break loop
            }
        }
    }
    
    receive(msg: JettonExcesses) {
         // if (context().sender == self.strategy_address) {
         //    
         // }
    }

    // --- Admin ---

    receive(msg: ResetProcessing) {
        require(context().sender == self.admin_address, "Only admin");
        
    }

    receive(msg: TogglePause) {
        require(context().sender == self.admin_address, "Only admin");
        self.is_paused = msg.paused;
    }

    receive(msg: ProcessWithdrawals) {
        require(context().sender == self.admin_address, "Only admin");
        self.processWithdrawals(msg.limit);
    }

    receive(msg: TimelockAction) {
        require(context().sender == self.admin_address, "Only admin");
        require(msg.execution_time >= now() + self.timelock_delay, "Delay too short");
        
        self.pending_actions.set(msg.action_id, msg);
    }
    
    receive(msg: ExecuteTimelock) {
         let action: TimelockAction? = self.pending_actions.get(msg.action_id);
         require(action != null, "Action not found");
         require(now() >= action!!.execution_time, "Time lock not expired");
         
         // Execute
         send(SendParameters{
             to: myAddress(),
             value: 0,
             mode: SendRemainingValue,
             bounce: false,
             body: action!!.payload
         });
         
         self.pending_actions.set(msg.action_id, null);
    }
    
    receive(msg: SetStrategy) {
        require(context().sender == self.admin_address, "Only admin");
        // This is a legacy/simple single strategy update if needed
        // For multi-strategy, use AddStrategy
    }

    receive(msg: AddStrategy) {
        require(context().sender == self.admin_address, "Only admin");
        
        // Check if already exists
        if (self.strategy_info.get(msg.strategy) != null) {
            throw(49088); // Strategy exists
        }
        
        self.strategies.set(self.strategies_count, msg.strategy);
        self.strategy_info.set(msg.strategy, StrategyParams{
            active: true,
            weight: msg.weight,
            balance: 0,
            current_apy: 0,
            is_nova: msg.is_nova
        });
        self.strategies_count = self.strategies_count + 1;
    }

    receive(msg: SetStrategyAllocation) {
        require(context().sender == self.admin_address, "Only admin");
        let info: StrategyParams? = self.strategy_info.get(msg.strategy);
        require(info != null, "Unknown strategy");
        
        self.strategy_info.set(msg.strategy, StrategyParams{
            active: info!!.active,
            weight: msg.weight,
            balance: info!!.balance,
            current_apy: info!!.current_apy,
            is_nova: info!!.is_nova
        });
    }

    /**
     * @notice Rebalance assets between strategies based on target weights
     */
    receive("Rebalance") {
        let ctx: Context = context();
        // Allow admin or permissionless with small bounty? For now, admin only for safety.
        require(ctx.sender == self.admin_address, "Only admin");

        let total_managed_assets: Int = self.total_strategy_balance + self.stored_balance;
        if (total_managed_assets == 0) { return; }

        let i: Int = 0;
        while (i < self.strategies_count) {
            let strat_addr: Address? = self.strategies.get(i);
            if (strat_addr != null) {
                let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                if (info != null && info!!.active) {
                    let target_bal: Int = (total_managed_assets * info!!.weight) / self.TOTAL_WEIGHT;
                    let current_bal: Int = info!!.balance;

                    if (current_bal > target_bal) {
                        // Divest excess
                        let diff: Int = current_bal - target_bal;
                        if (diff > self.MIN_WITHDRAWAL) { 
                            send(SendParameters{
                                to: strat_addr!!,
                                value: self.GAS_INVEST_MSG, 
                                mode: SendPayGasSeparately,
                                bounce: true,
                                body: Divest{ amount: diff }.toCell()
                            });
                        }
                    } else if (target_bal > current_bal) {
                        // Invest shortfall from stored_balance
                        let diff: Int = target_bal - current_bal;
                        let to_invest: Int = diff;
                        if (to_invest > self.stored_balance) { to_invest = self.stored_balance; }
                        
                        if (to_invest > self.MIN_WITHDRAWAL) { 
                            send(SendParameters{
                                to: strat_addr!!,
                                value: to_invest + self.GAS_INVEST_MSG,
                                mode: SendPayGasSeparately,
                                bounce: true,
                                body: Invest{ amount: to_invest }.toCell()
                            });
                            self.stored_balance -= to_invest;
                            // Optimistic update
                            self.strategy_info.set(strat_addr!!, StrategyParams{
                                active: info!!.active,
                                weight: info!!.weight,
                                balance: info!!.balance + to_invest,
                                current_apy: info!!.current_apy,
                                is_nova: info!!.is_nova
                            });
                            self.total_strategy_balance += to_invest;
                        }
                    }
                }
            }
            i = i + 1;
        }
    }

    receive(msg: PanicWithdraw) {
        require(context().sender == self.admin_address, "Only admin");
        
        
        
        
        // Broadcast Panic to all active strategies
        let i: Int = 0;
        while (i < self.strategies_count) {
             let strat_addr: Address? = self.strategies.get(i);
             if (strat_addr != null) {
                 let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                 if (info != null && info!!.active) {
                     send(SendParameters{
                        to: strat_addr!!,
                        value: self.GAS_PANIC, 
                        mode: SendPayGasSeparately,
                        bounce: true,
                        body: PanicWithdraw{}.toCell()
                    });
                    // Panic does not change stored_balance immediately
                 }
             }
             i = i + 1;
        }
    }

    receive(msg: MigrateStrategy) {
        require(context().sender == self.admin_address || context().sender == myAddress(), "Only admin or timelock");
        
        
        let oldInfo: StrategyParams? = self.strategy_info.get(msg.old_strategy);
        let newInfo: StrategyParams? = self.strategy_info.get(msg.new_strategy);
        
        require(oldInfo != null, "Old strategy not found");
        require(newInfo != null, "New strategy not found");
        require(oldInfo!!.balance >= msg.amount, "Insufficient balance");
        
        
        self.migration_target = msg.new_strategy;
        self.migration_amount = msg.amount;
        
        
        // Request Divest from Old Strategy
        send(SendParameters{
            to: msg.old_strategy,
            value: self.GAS_DIVEST_MIGRATE, 
            mode: SendPayGasSeparately,
            bounce: true,
            body: Divest{
                amount: msg.amount
            }.toCell()
        });
        // Divest does not change stored_balance
    }

    receive(msg: WithdrawEmergency) {
        require(context().sender == self.admin_address, "Only admin");
        
        let amount: Int = msg.amount;
        if (amount > myBalance() - self.GAS_DIVEST_MIGRATE) {
            amount = myBalance() - self.GAS_DIVEST_MIGRATE;
        }
        
        send(SendParameters{
            to: self.admin_address,
            value: amount,
            mode: SendIgnoreErrors,
            body: "Emergency Withdrawal".asComment()
        });
        
        // Update accounting if it was part of stored_balance
        if (amount > self.stored_balance) {
            self.total_assets -= self.stored_balance;
            self.stored_balance = 0;
        } else {
            self.stored_balance -= amount;
            self.total_assets -= amount;
        }
    }

    receive(msg: TransferOwnership) {
        require(context().sender == self.admin_address, "Only admin");
        self.admin_address = msg.new_owner;
    }

    receive(msg: SetEmergencyMode) {
        require(context().sender == self.admin_address || context().sender == self.recovery_address, "Access denied: Not Admin or Recovery");
        
        if (context().sender == self.recovery_address) {
            require(msg.is_emergency == true, "Recovery can only enable emergency");
        }
        
        
    }

    // --- Jetton Master Logic ---

    fun mint(to: Address, amount: Int) {
        self.total_shares = self.total_shares + amount;
        let init: StateInit = initOf JettonWallet(myAddress(), to);
        send(SendParameters{
            to: contractAddress(init),
            value: self.GAS_MINT, 
            mode: SendPayGasSeparately,
            bounce: true,
            body: JettonInternalTransfer{
                query_id: 0,
                amount: amount,
                from: myAddress(),
                response_destination: self.admin_address,
                forward_ton_amount: 0,
                forward_payload: null
            }.toCell(),
            code: init.code,
            data: init.data
        });
    }

    fun _requireWallet(sender: Address, owner: Address) {
        let init: StateInit = initOf JettonWallet(myAddress(), owner);
        require(contractAddress(init) == sender, "Invalid jetton wallet");
    }

    get fun get_strategy_info(strategy: Address): StrategyParams? {
        return self.strategy_info.get(strategy);
    }

    get fun get_jetton_data(): JettonData {
        return JettonData{
            total_supply: self.total_shares,
            mintable: self.mintable,
            admin_address: self.admin_address,
            jetton_content: self.content,
            jetton_wallet_code: (initOf JettonWallet(myAddress(), self.admin_address)).code
        };
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf JettonWallet(myAddress(), owner));
    }

    get fun get_pps(): Int {
         // Use total_assets for accurate PPS calculation (excludes gas reserves)
         let effective_assets: Int = self.total_assets;
         
         if (self.total_shares == 0) { return self.PPS_PRECISION; }
         return (effective_assets * self.PPS_PRECISION) / self.total_shares; // Scaled by 10^12
    }
}



struct PendingWithdrawal {
    user: Address;
    amount: Int as coins; // Net amount to user
    gross_amount: Int as coins; // Gross amount (including fee)
}
