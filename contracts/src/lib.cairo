#[starknet::interface]
pub trait IContract {
    fn get_value(self: @ContractState) -> u64;
    fn set_value(ref self: ContractState, value: u64);
}

#[contract]
mod Contract {
    use starknet::SyscallResult;
    use starknet::get_caller_address;

    #[storage]
    struct Storage {
        value: u64,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.value.set(42);
    }

    #[external]
    fn get_value(self: @ContractState) -> u64 {
        self.value.read()
    }

    #[external]
    fn set_value(ref self: ContractState, value: u64) {
        self.value.write(value);
    }
}
