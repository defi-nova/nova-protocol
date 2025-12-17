import "./messages.tact";
import "./jetton_wallet.tact";

contract Vault {
    const minTonsForStorage: Int = ton("0.1"); // Increased for safety
    const gasConsumption: Int = ton("0.1"); // Increased for safety
    const PPS_PRECISION: Int = 1000000000000; // 10^12

    total_shares: Int as coins;
    // strategy_address: Address; // Replaced by strategies map
    admin_address: Address;
    recovery_address: Address; // Admin Recovery
    locked_assets: Int as coins; // Assets currently being moved/locked
    // strategy_balance: Int as coins; // Replaced by aggregation
    
    // Multi-Strategy Storage
    strategies: map<Int, Address>; // ID -> Address
    strategy_info: map<Address, StrategyParams>; // Address -> Info
    strategies_count: Int;
    total_strategy_balance: Int as coins; // Aggregated balance
    stored_balance: Int as coins; // Internal balance tracking for PPS security

    // Withdrawal Queue
    // We use a mapping with integer keys to simulate a queue
    // key: index, value: PendingWithdrawal
    withdrawal_queue: map<Int, PendingWithdrawal>;
    queue_head: Int;
    queue_tail: Int;

    // Jetton Params
    content: Cell;
    mintable: Bool;

    // Status Flags
    is_processing: Bool;
    emergency_mode: Bool;
    is_paused: Bool;

    // Migration State
    migration_target: Address?;
    migration_amount: Int?;
    min_amount_out: Int?; // Added slippage protection

    init(admin: Address, recovery: Address, content: Cell) {
        self.total_shares = 0;
        // self.strategy_address = strategy; // Removed
        self.admin_address = admin;
        self.recovery_address = recovery;
        self.locked_assets = 0;
        // self.strategy_balance = 0; // Removed
        self.content = content;
        self.mintable = true;
        self.is_processing = false;
        self.emergency_mode = false;
        self.is_paused = false;
        self.migration_target = null;
        self.migration_amount = null;
        self.min_amount_out = null;
        
        self.queue_head = 0;
        self.queue_tail = 0;
        
        self.strategies_count = 0;
        self.total_strategy_balance = 0;
        self.stored_balance = 0;
        self.timelock_delay = 86400; // 24 hours default
        self.last_action_id = 0;
    }

    receive() {
        // Accept incoming TON but do not update stored_balance to prevent Force Feed manipulation
    }

    // --- User Interactions ---

    /**
     * @notice Deposit TON to mint shares
     * @param msg Deposit message containing amount and min_shares
     */
    receive(msg: Deposit) {
        let ctx: Context = context();
        require(!self.is_paused, "Protocol Paused");
        require(!self.is_processing, "Vault is processing");
        require(!self.emergency_mode, "Vault in emergency mode");
        
        // Update stored balance with deposit amount only (excluding gas)
        self.stored_balance = self.stored_balance + msg.amount;
        
        // Calculate PPS and Shares
        // Assets before this deposit (using stored_balance which now includes current deposit, so subtract it)
        let current_balance: Int = self.stored_balance - msg.amount; 
        if (current_balance < self.minTonsForStorage) {
            current_balance = 0;
        } else {
            current_balance = current_balance - self.minTonsForStorage;
        }
        
        let deposit_amount: Int = msg.amount; 
        // Verify attached value covers deposit + gas
        require(ctx.value >= deposit_amount + self.minTonsForStorage + self.gasConsumption, "Insufficient value");

        let total_assets: Int = current_balance + self.total_strategy_balance;
        let shares_to_mint: Int = 0;

        if (self.total_shares == 0) {
            shares_to_mint = deposit_amount;
        } else {
            // PPS = total_assets * PPS_PRECISION / total_shares
            // shares = amount * PPS_PRECISION / PPS = amount * PPS_PRECISION / (total_assets * PPS_PRECISION / total_shares)
            // shares = amount * total_shares / total_assets
            shares_to_mint = (deposit_amount * self.total_shares) / total_assets;
        }

        require(shares_to_mint >= msg.min_shares, "Slippage protection");

        // Mint Shares
        self.mint(ctx.sender, shares_to_mint);

        // Lock and Transfer to Strategy
        self.is_processing = true;
        self.locked_assets = deposit_amount;
        
        // Invest in strategies based on allocation
        // For MVP, we iterate and split
        let remaining: Int = deposit_amount;
        let gas_per_msg: Int = ton("0.05"); // Need simpler gas mgmt
        
        // Update stored_balance for locked assets
        // When we send money out, we decrease stored_balance
        // locked_assets is just for tracking what is "in transit" logic, but stored_balance tracks actual TON in contract
        
        // Iterate through strategies
        let i: Int = 0;
        
        while (i < self.strategies_count) {
             let strat_addr: Address? = self.strategies.get(i);
             if (strat_addr != null) {
                 let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                 if (info != null && info!!.active && info!!.weight > 0) {
                      // Calculate amount
                      let invest_amount: Int = (deposit_amount * info!!.weight) / 10000;
                      if (invest_amount > remaining) { invest_amount = remaining; }
                      
                      if (invest_amount > 0) {
                          // Optimistic Balance Update
                          self.strategy_info.set(strat_addr!!, StrategyParams{
                              active: info!!.active,
                              weight: info!!.weight,
                              balance: info!!.balance + invest_amount
                          });
                          self.total_strategy_balance = self.total_strategy_balance + invest_amount;
                          self.locked_assets = self.locked_assets - invest_amount;
                          self.stored_balance = self.stored_balance - invest_amount; // Only subtract amount

                          send(SendParameters{
                              to: strat_addr!!,
                              value: invest_amount + gas_per_msg, 
                              mode: SendPayGasSeparately, 
                              bounce: true,
                              body: Invest{
                                  amount: invest_amount
                              }.toCell()
                          });
                          remaining = remaining - invest_amount;
                      }
                 }
             }
             i = i + 1;
        }
        
        // If anything remaining (due to rounding or no strategies), keep in Vault
        // or send to first strategy?
        // For now, keep in Vault (it will increase PPS on next calc as idle funds)
    }

    /**
     * @notice Handle Jetton Burn (Withdrawal request)
     * @dev Checks liquidity and either pays immediately or queues withdrawal
     */
    receive(msg: JettonBurnNotification) {
        let ctx: Context = context();
        self._requireWallet(ctx.sender, msg.sender); // Validate sender is correct wallet
        require(!self.is_processing, "Vault is processing");

        let shares_burned: Int = msg.amount;
        
        // Calculate Withdrawal Amount
        let current_balance: Int = self.stored_balance - ctx.value; // Use stored_balance
        if (current_balance < self.minTonsForStorage) {
            current_balance = 0;
        } else {
            current_balance = current_balance - self.minTonsForStorage;
        }

        let total_assets: Int = current_balance + self.total_strategy_balance;
        
        // value = shares * total_assets / total_shares
        let withdraw_amount: Int = (shares_burned * total_assets) / self.total_shares;

        self.total_shares = self.total_shares - shares_burned;

        // Check liquidity
        let available_liquidity: Int = self.stored_balance - self.minTonsForStorage; // Use stored_balance
        if (available_liquidity < 0) { available_liquidity = 0; }

        if (available_liquidity >= withdraw_amount) {
            // Pay directly
            self.stored_balance = self.stored_balance - withdraw_amount;
            send(SendParameters{
                to: msg.response_destination,
                value: withdraw_amount,
                mode: SendRemainingValue, // Send remaining gas back
                bounce: false,
                body: "Withdrawal".asComment()
            });
        } else {
            // Queue withdrawal and request divest
            
            // 1. Add to Queue
            self.withdrawal_queue.set(self.queue_tail, PendingWithdrawal{
                user: msg.response_destination,
                amount: withdraw_amount
            });
            self.queue_tail = self.queue_tail + 1;

            // 2. Request Divest
            self.is_processing = true;
            let needed: Int = withdraw_amount - available_liquidity;
            
            // We request 'needed' from strategies
            // Simple logic: Request from first active strategy or distribute?
            // Distribute divest based on weights or availability?
            // For MVP: Iterate and divest until satisfied?
            // That's complex async. 
            // Better: Request from *largest* balance strategy?
            // Or just loop 0..N.
            
            let remaining_needed: Int = needed;
            let j: Int = 0;
            while (j < self.strategies_count && remaining_needed > 0) {
                let strat_addr: Address? = self.strategies.get(j);
                if (strat_addr != null) {
                    let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                    if (info != null && info!!.active && info!!.balance > 0) {
                        let pull: Int = remaining_needed;
                        if (pull > info!!.balance) { pull = info!!.balance; }
                        
                        send(SendParameters{
                            to: strat_addr!!,
                            value: ton("0.05"), // Gas
                            mode: SendPayGasSeparately,
                            bounce: true,
                            body: Divest{
                                amount: pull
                            }.toCell()
                        });
                        // Divest request does not change stored_balance yet, we wait for Refund
                        
                        remaining_needed = remaining_needed - pull;
                    }
                }
                j = j + 1;
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
        
        // Security Check: Max 20% profit jump
        if (old_bal > 0) {
            let limit: Int = (old_bal * 120) / 100;
            require(new_bal <= limit, "Security Alert: Profit too high");
        }
        
        // Update Info
        self.strategy_info.set(sender, StrategyParams{
            active: true,
            weight: info!!.weight,
            balance: new_bal
        });
        
        // Update Total
        self.total_strategy_balance = self.total_strategy_balance - old_bal + new_bal;
    }

    receive("StrategyConfirmation") {
        let sender: Address = context().sender;
        let info: StrategyParams? = self.strategy_info.get(sender);
        require(info != null, "Unknown strategy");
        
        self.is_processing = false; 
        
        // We rely on optimistic updates during Invest, so locked_assets should be 0 (or close to 0)
        // If we want to be safe, we can ensure it doesn't go negative?
        // But for now, we just acknowledge.
    }

    receive(msg: StrategyRefund) {
        // Security Fix: Verify sender is a known strategy
        let info: StrategyParams? = self.strategy_info.get(context().sender);
        require(info != null, "Security Alert: Unknown strategy sender");
        
        self.is_processing = false;
        
        // Update stored_balance with incoming refund amount
        self.stored_balance = self.stored_balance + msg.amount;
        
        // Update balance of that strategy?
        // The refund implies balance decreased in strategy and moved to Vault.
        // Strategy should have sent UpdatePPS before refunding?
        // Or we deduce it.
        // Let's assume Strategy sends UpdatePPS when balance changes.
        
        // MIGRATION LOGIC
        if (self.migration_target != null) {
            // Check if this refund is from the old strategy?
            // We assume if migration is active, any refund is part of it?
            // Or strictly from source?
            // Ideally we should have checked sender, but for now we trust flow.
            
            let amount: Int = self.stored_balance - self.minTonsForStorage; // Use stored_balance
            // We want to send `migration_amount` or whatever we got.
            
            if (amount > 0) {
                 let target: Address = self.migration_target!!;
                 let targetInfo: StrategyParams? = self.strategy_info.get(target);
                 
                 if (targetInfo != null && targetInfo!!.active) {
                     // Optimistic update for target
                     self.strategy_info.set(target, StrategyParams{
                          active: targetInfo!!.active,
                          weight: targetInfo!!.weight,
                          balance: targetInfo!!.balance + amount
                     });
                     self.total_strategy_balance = self.total_strategy_balance + amount;
                     
                     // Optimistic update for source (sender) - actually source balance decreased when we sent Divest?
                     // No, we didn't update source balance on Divest.
                     // So we should update it here?
                     // Wait, if source sent refund, its balance decreased.
                     // We should decrease it in `strategy_info`.
                     // But we don't know exact amount refunded unless we check `amount`.
                     // `amount` here is what Vault HAS.
                     
                     // Update Sender (Old Strategy) Balance
                     let senderInfo: StrategyParams = info!!;
                     let newSenderBal: Int = senderInfo.balance - amount;
                     if (newSenderBal < 0) { newSenderBal = 0; }
                     
                     self.strategy_info.set(context().sender, StrategyParams{
                         active: senderInfo.active,
                         weight: senderInfo.weight,
                         balance: newSenderBal
                     });
                     self.total_strategy_balance = self.total_strategy_balance - amount; // Decrease old (net change 0 if we add to new)
                     
                     // Send Invest to New Strategy
                     // Check Slippage Protection
                     require(amount >= self.min_amount_out!!, "Slippage protection: Output amount too low");

                     send(SendParameters{
                        to: target,
                        value: amount + ton("0.05"), 
                        mode: SendPayGasSeparately, 
                        bounce: true,
                        body: Invest{
                            amount: amount
                        }.toCell()
                     });
                     self.stored_balance = self.stored_balance - amount;
                 }
            }
            
            // Clear Migration State
            self.migration_target = null;
            self.migration_amount = null;
            return;
        }

        // Process Withdrawal Queue
        self.processWithdrawals(50);
    }

    fun processWithdrawals(limit: Int) {
        let available: Int = self.stored_balance - self.minTonsForStorage; 
        if (available < 0) { available = 0; }
        
        let count: Int = 0;
        
        while (self.queue_head < self.queue_tail && available > 0 && count < limit) {
            let req: PendingWithdrawal = self.withdrawal_queue.get(self.queue_head)!!;
            
            if (available >= req.amount) {
                // Pay user
                send(SendParameters{
                    to: req.user,
                    value: req.amount,
                    mode: SendPayGasSeparately, 
                    bounce: false,
                    body: "Withdrawal".asComment()
                });
                self.stored_balance = self.stored_balance - req.amount;
                
                available = available - req.amount;
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
         //    self.is_processing = false;
         // }
    }

    // --- Admin ---

    receive(msg: ResetProcessing) {
        require(context().sender == self.admin_address, "Only admin");
        self.is_processing = false;
    }

    receive(msg: TogglePause) {
        require(context().sender == self.admin_address, "Only admin");
        self.is_paused = msg.paused;
    }

    receive(msg: ProcessWithdrawals) {
        require(context().sender == self.admin_address, "Only admin");
        self.processWithdrawals(msg.limit);
    }

    // TIMELOCK LOGIC
    timelock_delay: Int; // Seconds
    pending_actions: map<Int, TimelockAction>;
    last_action_id: Int;

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
    
    receive(msg: AddStrategy) {
        require(context().sender == self.admin_address || context().sender == myAddress(), "Only admin or timelock");
        require(self.strategy_info.get(msg.strategy) == null, "Strategy exists");
        
        self.strategies.set(self.strategies_count, msg.strategy);
        self.strategies_count = self.strategies_count + 1;
        
        self.strategy_info.set(msg.strategy, StrategyParams{
            active: true,
            weight: msg.weight,
            balance: 0
        });
    }

    receive(msg: SetStrategyAllocation) {
        require(context().sender == self.admin_address, "Only admin");
        let info: StrategyParams? = self.strategy_info.get(msg.strategy);
        require(info != null, "Unknown strategy");
        
        self.strategy_info.set(msg.strategy, StrategyParams{
            active: info!!.active,
            weight: msg.weight,
            balance: info!!.balance
        });
    }

    receive(msg: PanicWithdraw) {
        require(context().sender == self.admin_address, "Only admin");
        require(!self.is_processing, "Already processing");
        
        self.is_processing = true;
        
        // Broadcast Panic to all active strategies
        let i: Int = 0;
        while (i < self.strategies_count) {
             let strat_addr: Address? = self.strategies.get(i);
             if (strat_addr != null) {
                 let info: StrategyParams? = self.strategy_info.get(strat_addr!!);
                 if (info != null && info!!.active) {
                     send(SendParameters{
                        to: strat_addr!!,
                        value: ton("0.25"), // Increased to cover Strategy's withdrawal gas
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
        require(!self.is_processing, "Vault is processing");
        
        let oldInfo: StrategyParams? = self.strategy_info.get(msg.old_strategy);
        let newInfo: StrategyParams? = self.strategy_info.get(msg.new_strategy);
        
        require(oldInfo != null, "Old strategy not found");
        require(newInfo != null, "New strategy not found");
        require(oldInfo!!.balance >= msg.amount, "Insufficient balance");
        
        self.is_processing = true;
        self.migration_target = msg.new_strategy;
        self.migration_amount = msg.amount;
        self.min_amount_out = msg.min_amount_out;
        
        // Request Divest from Old Strategy
        send(SendParameters{
            to: msg.old_strategy,
            value: ton("0.1"), // Gas for divest
            mode: SendPayGasSeparately,
            bounce: true,
            body: Divest{
                amount: msg.amount
            }.toCell()
        });
        // Divest does not change stored_balance
    }

    receive(msg: SetStrategy) {
        require(context().sender == self.admin_address, "Only admin");
        // Deprecated single strategy setter? Or maybe repurpose to "Set Default"?
        // For now, ignore or throw error.
        // self.strategy_address = msg.new_strategy;
        throw(0xFFFF); // Not supported in Multi-Strategy mode
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
        
        self.emergency_mode = msg.is_emergency;
    }

    // --- Jetton Master Logic ---

    fun mint(to: Address, amount: Int) {
        self.total_shares = self.total_shares + amount;
        let init: StateInit = initOf JettonWallet(myAddress(), to);
        let wallet_address: Address = contractAddress(init);
        
        send(SendParameters{
            to: wallet_address,
            value: ton("0.05"), // Gas for minting
            mode: SendIgnoreErrors,
            bounce: true,
            body: JettonInternalTransfer{
                query_id: 0,
                amount: amount,
                from: myAddress(),
                response_destination: to,
                forward_ton_amount: 0,
                forward_payload: emptySlice()
            }.toCell(),
            code: init.code,
            data: init.data
        });
    }

    fun _requireWallet(sender: Address, owner: Address) {
        let init: StateInit = initOf JettonWallet(myAddress(), owner);
        require(contractAddress(init) == sender, "Invalid wallet");
    }

    get fun get_jetton_data(): JettonData {
        return JettonData{
            total_supply: self.total_shares,
            mintable: self.mintable,
            admin_address: self.admin_address,
            content: self.content,
            wallet_code: initOf JettonWallet(myAddress(), self.admin_address).code // Code is same for all
        };
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf JettonWallet(myAddress(), owner));
    }
    
    get fun get_pps(): Int {
         let balance: Int = self.stored_balance; // Use stored_balance
         if (balance < self.minTonsForStorage) {
             balance = 0;
         } else {
             balance = balance - self.minTonsForStorage;
         }
         let total_assets: Int = balance + self.total_strategy_balance + self.locked_assets;
         if (self.total_shares == 0) { return self.PPS_PRECISION; }
         return (total_assets * self.PPS_PRECISION) / self.total_shares; // Scaled by 10^12
    }
}

struct StrategyParams {
    active: Bool;
    weight: Int as uint16; // Basis points (10000 = 100%)
    balance: Int as coins;
}

struct JettonData {
    total_supply: Int;
    mintable: Bool;
    admin_address: Address;
    content: Cell;
    wallet_code: Cell;
}

struct PendingWithdrawal {
    user: Address;
    amount: Int as coins;
}
