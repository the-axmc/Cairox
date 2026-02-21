// Stub for market_factory - Cairo 2.x
#[starknet::contract]
mod MarketFactory {
    #[storage]
    struct Storage {
        initialized: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.initialized.write(true);
    }
}
