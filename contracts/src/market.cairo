// Stub for market - Cairo 2.x
#[starknet::contract]
mod Market {
    #[storage]
    struct Storage {
        initialized: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.initialized.write(true);
    }
}
