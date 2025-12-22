message(0x75) Deposit {
    amount: Int as coins;
    min_shares: Int as coins;
}

struct StrategyReport {
    total_invested: Int as coins;
    current_balance: Int as coins;
    evaa_balance: Int as coins;
    lp_balance: Int as coins;
    mode: Int as uint8;
}

message(0x88) Invest {
    amount: Int as coins;
}

message(0x15) Harvest {
    gas_limit: Int as coins;
    min_profit: Int as coins;
}

message(0x89) ClaimReward {
    // No params needed, just triggers claim
}

message(0x44) UpdatePPS {
    new_assets_value: Int as coins;
}

message(0x09) Divest {
    amount: Int as coins;
}

// TEP-74 Jetton Messages

message(0xf8a7ea5) JettonTransfer {
    query_id: Int as uint64;
    amount: Int as coins;
    destination: Address;
    response_destination: Address;
    custom_payload: Cell?;
    forward_ton_amount: Int as coins;
    forward_payload: Cell?; 
}

message(0x7362d09c) JettonTransferNotification {
    query_id: Int as uint64;
    amount: Int as coins;
    sender: Address;
    forward_payload: Cell?;
}

message(0x595f07bc) JettonBurn {
    query_id: Int as uint64;
    amount: Int as coins;
    response_destination: Address;
    custom_payload: Cell?;
}

message UpdateProtocolApy {
    strategy: Address;
    apy: Int as uint16;
}

struct StrategyApy {
    address: Address;
    apy: Int as uint16;
}

message RunNode {
    // No parameters, users only trigger rebalancing based on admin-set APY
}

message BatchUpdateApy {
    apys: map<Int, StrategyApy>;
}

message(0x7bdd97de) JettonBurnNotification {
    query_id: Int as uint64;
    amount: Int as coins;
    sender: Address;
    response_destination: Address;
}

message(0xd53276db) JettonExcesses {
    query_id: Int as uint64;
}

// DEX Messages (DeDust / STON.fi)
struct SwapAdditionalData {
    minOut: Int as coins;
    receiverAddress: Address;
    fwdGas: Int as coins;
    customPayload: Cell?;
    refundFwdGas: Int as coins;
    refundPayload: Cell?;
    refFee: Int as uint16;
    referralAddress: Address?;
}

message(0x6664de2a) StonfiSwap {
    otherTokenWallet: Address;
    refundAddress: Address;
    excessesAddress: Address;
    deadline: Int as uint64;
    additionalData: Cell; // Should be SwapAdditionalData
}

// STON.fi v2 LP Messages
message(0x37c0514a) StonfiProvideLiquidity {
    otherTokenWallet: Address;
    minLpOut: Int as coins;
    refundAddress: Address;
    excessesAddress: Address;
    deadline: Int as uint64;
}

// DeDust Messages
message(0xe3a0f35) DedustSwap {
    query_id: Int as uint64;
    amount: Int as coins;
    min_amount_out: Int as coins;
    deadline: Int as uint32;
    recipient: Address;
}

message(0x40e10f03) DedustLiquidityDeposit {
    query_id: Int as uint64;
    min_lp_out: Int as coins;
    deadline: Int as uint32;
}

// EVAA Messages
message(0x1) EvaaSupply {
    query_id: Int as uint64;
    amount: Int as coins;
    user_address: Address;
    include_user_code: Int as uint1;
    amount_to_transfer: Int as coins;
    payload: Cell?;
}

message(0x2) EvaaWithdraw {
    query_id: Int as uint64;
    amount: Int as coins;
    user_address: Address;
    include_user_code: Int as uint1;
    amount_to_transfer: Int as coins;
    payload: Cell?;
}

struct EvaaAssetData {
    balance: Int as coins;
    borrow: Int as coins;
}

message(0x3) EvaaUserScData {
    user: Address;
    assets: map<Int, EvaaAssetData>; // Assets Dictionary
}

message(0x68) WithdrawEmergency {
    amount: Int as coins;
}

message(0x67) SetEvaaMaster {
    evaa_master: Address;
}

message SetDexAddresses {
    dedust_factory: Address;
    dedust_vault: Address;
    stonfi_router: Address;
    stonfi_pton: Address;
    usdt_master: Address;
}

message SetJettonWallets {
    usdt: Address?;
    lp_token: Address?;
}

message SwapToJetton {
    dex_type: Int as uint8; // 0 for DeDust, 1 for STON.fi
    amount: Int as coins;
    min_amount_out: Int as coins;
}

// Internal
message(0x99) Report {
    profit: Int as coins;
    loss: Int as coins;
}

message(0x100) SetStrategy {
    new_strategy: Address;
}

message(0x105) AddStrategy {
    strategy: Address;
    weight: Int as uint16; // Basis points (10000 = 100%)
}

message(0x106) SetStrategyAllocation {
    strategy: Address;
    weight: Int as uint16;
}

message(0x107) RemoveStrategy {
    strategy: Address;
}

message(0x101) SetAdmin {
    new_admin: Address;
}

message(0x103) TransferOwnership {
    new_owner: Address;
}

message(0x104) SetEmergencyMode {
    is_emergency: Bool;
}

message(0x102) PanicWithdraw {
}

message(0x55) StrategyRefund {
    amount: Int as coins; // Optional: if we want to explicitly state amount, though value is attached
}

message(0x66) SetAssetId {
    asset_id: Int;
}

message SetStrategyMode {
    mode: Int as uint8;
}

message(0x888) MigrateStrategy {
    old_strategy: Address;
    new_strategy: Address;
    amount: Int as coins;
    min_amount_out: Int as coins; // Added slippage protection
}

message(0x999) TimelockAction {
    action_id: Int; 
    payload: Cell;
    execution_time: Int;
}

message ResetProcessing {}

message TogglePause {
    paused: Bool;
}

message ProcessWithdrawals {
    limit: Int;
}

message(0x889) ExecuteTimelock {
    action_id: Int;
}

message(0x178d4519) JettonInternalTransfer {
    query_id: Int as uint64;
    amount: Int as coins;
    from: Address;
    response_destination: Address;
    forward_ton_amount: Int as coins;
    forward_payload: Cell?;
}
