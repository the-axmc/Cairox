#[starknet::contract]
mod Market {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
