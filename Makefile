include .env

.PHONY: all test clean

install:
	forge install

test:
	forge test --isolate --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

sim-deploy-base-sepolia-hook:
	@forge script ./script/BaseSepoliaMulticurveFeeHook.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

deploy-base-sepolia-hook:
	@forge script ./script/BaseSepoliaMulticurveFeeHook.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --broadcast --slow

sim-deploy-base-sepolia-milestone-unlock-hook:
	@forge script ./script/BaseSepoliaMilestoneUnlockHook.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL)

deploy-base-sepolia-milestone-unlock-hook:
	@forge script ./script/BaseSepoliaMilestoneUnlockHook.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --broadcast --slow

create-token:
	@forge script ./script/CreateTokenWithNewInitializer.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --broadcast --slow

verify:
	@forge verify-contract $(CONTRACT_ADDRESS) $(CONTRACT_NAME) --show-standard-json-input > $(CONTRACT_NAME)_standard_json_input.json