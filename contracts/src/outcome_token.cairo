// Stub for outcome_token - Cairo 2.x
#[starknet::contract]
mod OutcomeToken {
    #[storage]
    struct Storage {
        initialized: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.initialized.write(true);
    }
}
