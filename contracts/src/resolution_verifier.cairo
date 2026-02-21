#[starknet::contract]
mod ResolutionVerifier {
    #[storage]
    struct Storage {
        initialized: bool,
    }
}
