// CollateralVault - User deposits and balance management with ERC20 transfers

use starknet::ContractAddress;

#[starknet::interface]
trait IERC20<TContractState> {
    fn transfer(ref self: TContractState, to: ContractAddress, amount: u256) -> bool;
    fn transfer_from(
        ref self: TContractState,
        from: ContractAddress,
        to: ContractAddress,
        amount: u256
    ) -> bool;
}

#[starknet::interface]
trait ICollateralVault<TContractState> {
    fn settle_to_relayer(
        ref self: TContractState,
        user: ContractAddress,
        amount: u256,
        to: ContractAddress
    );
}

#[starknet::contract]
mod CollateralVault {
    use super::{ContractAddress, IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::SyscallResultTrait;
    use starknet::class_hash::ClassHash;
    use starknet::storage::Map;
    use starknet::storage::StoragePointerReadAccess;
    use starknet::storage::StoragePointerWriteAccess;
    use starknet::syscalls::replace_class_syscall;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        pending_owner: ContractAddress,
        collateral_token: ContractAddress,
        balances: Map<ContractAddress, u256>,
        total_deposited: u256,
        paused: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposited: Deposited,
        Withdrawn: Withdrawn,
        Settled: Settled,
        OwnershipTransferStarted: OwnershipTransferStarted,
        OwnershipTransferred: OwnershipTransferred,
        Paused: Paused,
        Unpaused: Unpaused,
        Upgraded: Upgraded,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Deposited {
        #[key]
        account: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Withdrawn {
        #[key]
        account: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Settled {
        #[key]
        account: ContractAddress,
        #[key]
        relayer: ContractAddress,
        amount: u256,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferStarted {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct OwnershipTransferred {
        #[key]
        previous_owner: ContractAddress,
        #[key]
        new_owner: ContractAddress,
    }

    #[derive(Copy, Drop, starknet::Event)]
    struct Paused {}

    #[derive(Copy, Drop, starknet::Event)]
    struct Unpaused {}

    #[derive(Copy, Drop, starknet::Event)]
    struct Upgraded {
        class_hash: ClassHash,
    }

    #[constructor]
    fn constructor(ref self: ContractState, collateral_token: ContractAddress) {
        let owner = deployer_address();
        self.owner.write(owner);
        self.pending_owner.write(zero_address());
        self.collateral_token.write(collateral_token);
        self.total_deposited.write(u256 { low: 0, high: 0 });
        self.paused.write(false);
    }

    // Ownership transfer
    #[external(v0)]
    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.pending_owner.write(new_owner);
        self.emit(OwnershipTransferStarted { previous_owner: current, new_owner });
    }

    #[external(v0)]
    fn accept_ownership(ref self: ContractState) {
        let pending = self.pending_owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == pending, 'Not pending owner');
        let previous = self.owner.read();
        self.owner.write(pending);
        self.pending_owner.write(zero_address());
        self.emit(OwnershipTransferred { previous_owner: previous, new_owner: pending });
    }

    // Pause/unpause
    #[external(v0)]
    fn pause(ref self: ContractState) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.paused.write(true);
        self.emit(Paused {});
    }

    #[external(v0)]
    fn unpause(ref self: ContractState) {
        let current = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == current, 'Not owner');
        self.paused.write(false);
        self.emit(Unpaused {});
    }

    #[external(v0)]
    fn deposit(ref self: ContractState, amount: u256) {
        assert(!self.paused.read(), 'Paused');
        assert(!is_zero_u256(amount), 'Zero amount');

        let caller = starknet::get_caller_address();
        let token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let vault = starknet::get_contract_address();
        let ok = token.transfer_from(caller, vault, amount);
        assert(ok, 'Transfer failed');

        let current = self.balances.read(caller);
        self.balances.write(caller, current + amount);

        let total = self.total_deposited.read();
        self.total_deposited.write(total + amount);
        self.emit(Deposited { account: caller, amount });
    }

    #[external(v0)]
    fn withdraw(ref self: ContractState, amount: u256) {
        assert(!self.paused.read(), 'Paused');
        assert(!is_zero_u256(amount), 'Zero amount');

        let caller = starknet::get_caller_address();
        let current = self.balances.read(caller);
        assert(current >= amount, 'Insufficient balance');

        self.balances.write(caller, current - amount);

        let total = self.total_deposited.read();
        self.total_deposited.write(total - amount);

        let token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = token.transfer(caller, amount);
        assert(ok, 'Transfer failed');
        self.emit(Withdrawn { account: caller, amount });
    }

    #[external(v0)]
    fn settle_to_relayer(
        ref self: ContractState,
        user: ContractAddress,
        amount: u256,
        to: ContractAddress
    ) {
        assert(!self.paused.read(), 'Paused');
        assert(!is_zero_u256(amount), 'Zero amount');
        let owner = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == owner, 'Not owner');

        let current = self.balances.read(user);
        assert(current >= amount, 'Insufficient balance');
        self.balances.write(user, current - amount);

        let total = self.total_deposited.read();
        self.total_deposited.write(total - amount);

        let token = IERC20Dispatcher { contract_address: self.collateral_token.read() };
        let ok = token.transfer(to, amount);
        assert(ok, 'Transfer failed');
        self.emit(Settled { account: user, relayer: to, amount });
    }

    // Admin-only reconciliation helpers. Require vault to be paused.
    #[external(v0)]
    fn admin_set_balance(ref self: ContractState, user: ContractAddress, amount: u256) {
        let owner = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == owner, 'Not owner');
        assert(self.paused.read(), 'Not paused');
        self.balances.write(user, amount);
    }

    #[external(v0)]
    fn admin_set_total_deposited(ref self: ContractState, amount: u256) {
        let owner = self.owner.read();
        let caller = starknet::get_caller_address();
        assert(caller == owner, 'Not owner');
        assert(self.paused.read(), 'Not paused');
        self.total_deposited.write(amount);
    }

    #[external(v0)]
    fn get_balance(self: @ContractState, user: ContractAddress) -> u256 {
        self.balances.read(user)
    }

    #[external(v0)]
    fn get_my_balance(self: @ContractState) -> u256 {
        let caller = starknet::get_caller_address();
        self.balances.read(caller)
    }

    #[external(v0)]
    fn get_total_deposited(self: @ContractState) -> u256 {
        self.total_deposited.read()
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn get_collateral_token(self: @ContractState) -> ContractAddress {
        self.collateral_token.read()
    }

    #[external(v0)]
    fn is_paused(self: @ContractState) -> bool {
        self.paused.read()
    }

    #[external(v0)]
    fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
        let caller = starknet::get_caller_address();
        let owner = self.owner.read();
        assert(caller == owner, 'Not owner');
        replace_class_syscall(new_class_hash).unwrap_syscall();
        self.emit(Upgraded { class_hash: new_class_hash });
    }

    fn zero_address() -> ContractAddress {
        0.try_into().unwrap()
    }

    fn deployer_address() -> ContractAddress {
        let tx_info = starknet::get_tx_info().unbox();
        tx_info.account_contract_address
    }

    fn is_zero_u256(value: u256) -> bool {
        value.low == 0 && value.high == 0
    }
}
