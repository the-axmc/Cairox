// LMSRMarketMaker - Binary outcome market maker
#[starknet::contract]
mod LMSRMarketMaker {
    use starknet::ContractAddress;
    use starknet::get_caller_address;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        market: ContractAddress,
        invariant: u128,
        yes_shares: u128,
        no_shares: u128,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress, market: ContractAddress, invariant: u128) {
        self.owner.write(owner);
        self.market.write(market);
        self.invariant.write(invariant);
        self.yes_shares.write(0);
        self.no_shares.write(0);
    }

    #[external(v0)]
    fn get_yes_price(self: @ContractState) -> u128 {
        let yes = self.yes_shares.read();
        let no = self.no_shares.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (yes * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn get_no_price(self: @ContractState) -> u128 {
        let yes = self.yes_shares.read();
        let no = self.no_shares.read();
        if yes + no == 0 {
            return 500000000000000000;
        }
        (no * 1000000000000000000) / (yes + no)
    }

    #[external(v0)]
    fn get_total_shares(self: @ContractState) -> u128 {
        self.yes_shares.read() + self.no_shares.read()
    }

    #[external(v0)]
    fn set_invariant(ref self: ContractState, new_invariant: u128) {
        assert(get_caller_address() == self.owner.read(), 'Only owner');
        self.invariant.write(new_invariant);
    }
}
