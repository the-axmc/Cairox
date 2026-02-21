// Stub for collateral_vault - Cairo 2.x
#[starknet::contract]
mod CollateralVault {
    #[storage]
    struct Storage {
        initialized: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.initialized.write(true);
    }
}
