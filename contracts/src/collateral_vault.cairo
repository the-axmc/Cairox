#[starknet::contract]
mod CollateralVault {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
