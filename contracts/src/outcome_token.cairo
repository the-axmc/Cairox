#[starknet::contract]
mod OutcomeToken {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
