import "./messages.tact";

contract JettonWallet {
    
    const gasConsumption: Int = ton("0.01");

    balance: Int as coins;
    owner: Address;
    master: Address;

    init(master: Address, owner: Address) {
        self.balance = 0;
        self.owner = owner;
        self.master = master;
    }

    receive(msg: JettonTransfer) {
        let ctx: Context = context();
        require(ctx.sender == self.owner, "Invalid sender");
        require(self.balance >= msg.amount, "Insufficient balance");
        
        self.balance = self.balance - msg.amount;
        require(self.balance >= 0, "Invalid balance");

        let fwdFee: Int = ctx.readForwardFee();
        let fwdCount: Int = 1;
        if (msg.forward_ton_amount > 0) {
            fwdCount = 2;
        }
        

        let init: StateInit = initOf JettonWallet(self.master, msg.destination);
        let walletAddress: Address = contractAddress(init);

        send(SendParameters{
            to: walletAddress,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonInternalTransfer{
                query_id: msg.query_id,
                amount: msg.amount,
                from: self.owner,
                response_destination: msg.response_destination,
                forward_ton_amount: msg.forward_ton_amount,
                forward_payload: msg.forward_payload
            }.toCell(),
            code: init.code,
            data: init.data
        });
    }

    receive(msg: JettonInternalTransfer) {
        let ctx: Context = context();
        if (ctx.sender != self.master) {
            let sinit: StateInit = initOf JettonWallet(self.master, self.owner);
            require(contractAddress(sinit) == ctx.sender, "Invalid sender");
        }

        self.balance = self.balance + msg.amount;
        require(self.balance >= 0, "Invalid balance");

        if (msg.forward_ton_amount > 0) {
            send(SendParameters{
                to: self.owner,
                value: msg.forward_ton_amount,
                mode: SendPayGasSeparately,
                bounce: false,
                body: JettonTransferNotification{
                    query_id: msg.query_id,
                    amount: msg.amount,
                    sender: msg.from,
                    forward_payload: msg.forward_payload
                }.toCell()
            });
        }

        if (true) {
            send(SendParameters{
                to: msg.response_destination,
                value: 0,
                bounce: false,
                mode: SendRemainingValue + SendIgnoreErrors,
                body: JettonExcesses{
                    query_id: msg.query_id
                }.toCell()
            });
        }
    }

    receive(msg: JettonBurn) {
        let ctx: Context = context();
        require(ctx.sender == self.owner, "Invalid sender");
        require(self.balance >= msg.amount, "Insufficient balance");
        require(msg.amount > 0, "Invalid amount");

        self.balance = self.balance - msg.amount;
        require(self.balance >= 0, "Invalid balance");

        let fwdFee: Int = ctx.readForwardFee();
        

        send(SendParameters{
            to: self.master,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonBurnNotification{
                query_id: msg.query_id,
                amount: msg.amount,
                sender: self.owner,
                response_destination: msg.response_destination
            }.toCell()
        });
    }

    receive(msg: JettonBurnNotification) {
         // This is usually for the master to receive, but if we are implementing minting logic where master sends mint to wallet...
         // Actually, standard jetton wallet doesn't receive BurnNotification.
         // But we need a message for Minting.
         // Let's call it JettonInternalTransfer but from Master.
         // I handled that in JettonInternalTransfer.
    }

    bounced(src: bounced<JettonInternalTransfer>) {
        self.balance = self.balance + src.amount;
    }

    bounced(src: bounced<JettonBurnNotification>) {
        self.balance = self.balance + src.amount;
    }

    get fun get_wallet_data(): JettonWalletData {
        return JettonWalletData{
            balance: self.balance,
            owner: self.owner,
            master: self.master,
            wallet_code: initOf JettonWallet(self.master, self.owner).code
        };
    }
}

struct JettonWalletData {
    balance: Int;
    owner: Address;
    master: Address;
    wallet_code: Cell;
}
