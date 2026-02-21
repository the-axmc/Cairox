#[starknet::contract]
mod MarketFactory {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
