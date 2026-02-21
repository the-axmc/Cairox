#[starknet::contract]
mod LMSRMarketMaker {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
