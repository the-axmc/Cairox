#[starknet::contract]
mod Arbitration {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
