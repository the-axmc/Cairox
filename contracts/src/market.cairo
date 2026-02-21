// Market - YES/NO prediction market

#[starknet::contract]
mod Market {
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    const PENDING: felt252 = 0;
    const ACTIVE: felt252 = 1;
    const RESOLVED: felt252 = 2;
    const OUTCOME_YES: felt252 = 1;
    const OUTCOME_NO: felt252 = 0;

    #[storage]
    struct Storage {
        owner: felt252,
        factory: felt252,
        question: felt252,
        collateral_deposits: Map<felt252, u256>,
        yes_balance: Map<felt252, u256>,
        no_balance: Map<felt252, u256>,
        total_collateral: u256,
        yes_supply: u256,
        no_supply: u256,
        status: felt252,
        winning_outcome: felt252,
        b: u256,
    }

    #[constructor]
    fn constructor(ref self: ContractState, factory: felt252, question: felt252, b: u256) {
        self.owner.write(0);
        self.factory.write(factory);
        self.question.write(question);
        self.total_collateral.write(u256 { low: 0, high: 0 });
        self.yes_supply.write(u256 { low: 0, high: 0 });
        self.no_supply.write(u256 { low: 0, high: 0 });
        self.status.write(ACTIVE);
        self.winning_outcome.write(0);
        self.b.write(b);
    }

    #[external(v0)]
    fn buy(ref self: ContractState, outcome: felt252, collateral_amount: u256, min_tokens: u256) -> u256 {
        assert(self.status.read() == ACTIVE, 'Market not active');
        
        let buyer: felt252 = starknet::get_contract_address().into();
        let tokens_out = collateral_amount;
        assert(tokens_out >= min_tokens, 'Slippage exceeded');
        
        let current = self.collateral_deposits.read(buyer);
        self.collateral_deposits.write(buyer, current + collateral_amount);
        
        let total = self.total_collateral.read();
        self.total_collateral.write(total + collateral_amount);
        
        if outcome == OUTCOME_YES {
            let current = self.yes_balance.read(buyer);
            self.yes_balance.write(buyer, current + tokens_out);
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply + tokens_out);
        } else {
            let current = self.no_balance.read(buyer);
            self.no_balance.write(buyer, current + tokens_out);
            let supply = self.no_supply.read();
            self.no_supply.write(supply + tokens_out);
        };
        
        tokens_out
    }

    #[external(v0)]
    fn sell(ref self: ContractState, outcome: felt252, token_amount: u256, min_collateral: u256) -> u256 {
        assert(self.status.read() == ACTIVE, 'Market not active');
        
        let seller: felt252 = starknet::get_contract_address().into();
        let collateral_out = token_amount;
        assert(collateral_out >= min_collateral, 'Slippage exceeded');
        
        if outcome == OUTCOME_YES {
            let current = self.yes_balance.read(seller);
            assert(current >= token_amount, 'Insufficient tokens');
            self.yes_balance.write(seller, current - token_amount);
            let supply = self.yes_supply.read();
            self.yes_supply.write(supply - token_amount);
        } else {
            let current = self.no_balance.read(seller);
            assert(current >= token_amount, 'Insufficient tokens');
            self.no_balance.write(seller, current - token_amount);
            let supply = self.no_supply.read();
            self.no_supply.write(supply - token_amount);
        };
        
        collateral_out
    }

    #[external(v0)]
    fn resolve(ref self: ContractState, winning_outcome: felt252) {
        assert(self.status.read() == ACTIVE, 'Already resolved');
        self.status.write(RESOLVED);
        self.winning_outcome.write(winning_outcome);
    }

    #[external(v0)]
    fn redeem(ref self: ContractState) -> u256 {
        assert(self.status.read() == RESOLVED, 'Not resolved');
        
        let user: felt252 = starknet::get_contract_address().into();
        let winning = self.winning_outcome.read();
        
        let winnings = if winning == OUTCOME_YES {
            self.yes_balance.read(user)
        } else {
            self.no_balance.read(user)
        };
        
        self.yes_balance.write(user, u256 { low: 0, high: 0 });
        self.no_balance.write(user, u256 { low: 0, high: 0 });
        
        winnings
    }

    #[external(v0)]
    fn get_yes_price(self: @ContractState) -> u256 {
        u256 { low: 1, high: 0 }
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u256 {
        u256 { low: 1, high: 0 }
    }

    #[external(v0)]
    fn get_status(self: @ContractState) -> felt252 {
        self.status.read()
    }
}
