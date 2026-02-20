# Cairox Contracts - Makefile

.PHONY: test devnet-up deploy-local clean

# Default target
all: test

# Run all tests
test:
	@echo "Running Cairox tests..."
	@cd contracts && scarb test

# Start local devnet
devnet-up:
	@echo "Starting local Starknet devnet..."
	@starknet-devnet --seed 0 --account-class cairo1 &
	@sleep 5
	@echo "Devnet started at http://127.0.0.1:5050"

# Deploy contracts to local devnet
deploy-local: devnet-up
	@echo "Deploying contracts to local devnet..."
	@cd contracts && \
		scarb build && \
		snforge declare --name local && \
		snforge deploy --name local
	@echo "Contracts deployed successfully!"
	@echo "Contract addresses:"
	@cat contracts/deployments/local.json 2>/dev/null || echo "Run snforge deploy first"

# Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf contracts/target
	@rm -rf contracts/abi
	@rm -rf contracts/deployment
	@echo "Clean complete"