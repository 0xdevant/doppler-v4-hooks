# Doppler v4 hooks

## Overview

This is a repo built on top of [Doppler](https://github.com/whetstoneresearch/doppler). You can find here the:

1. smart contracts built on top of Doppler
2. test suite for integration tests and simulating full token launch flow

## Deployment

| Contract Name                         | Chain       | Address                                                                                                                       |
| ------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------- |
| UniswapV4MulticurveInitializerFeeHook | BaseSepolia | [0x7b71bD11cB29A9c9C3775de1bf7fe568d0A7653D](https://sepolia.basescan.org/address/0x7b71bd11cb29a9c9c3775de1bf7fe568d0a7653d) |

## Get Started

```bash
# Clone the repository
git clone <repository-url>
cd Launch-contracts

# Install Foundry (if not already installed)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install dependencies
make install
# Run tests
make test
```

Please specify respective environment variables in `.env` when

fork testing:

- `BASE_RPC_URL`: Base Mainnet RPC endpoint

running forge script:

- `BASE_RPC_URL`: Base Mainnet RPC endpoint
- `PRIVATE_KEY`: To run forge script for deploying contracts, keystore can be used as well

## Usage

### Deployment

<details>

<summary>Multicurve Hook Configs</summary>

#### For `UniswapV4MulticurveInitializerFeeHook.sol`

Specify the `deployConfig` in respective `*MulticurveHook.s.sol` which \* refers to respective network like `Base` or `BaseSepolia`:

```solidity
deployConfig = DeployConfig({
   airlock: Constants.BASE_SEPOLIA_AIRLOCK,
   manager: Constants.BASE_SEPOLIA_POOL_MANAGER,
   hookFeeWad: 0.01 ether // 1% fee
});
```

`airlock`: Doppler Airlock contract address

`manager`: Uniswap v4 Pool Manager contract address

`hookFeeWad`: Percentage of the hook fee taken in numeraire that will be split to all beneficiaries in WAD (0.1e18 = 10%)

P.S.: You may specify `initializerName` and `hookName` for the name of the markdown files generated from the deployment as well.

</details>

#### Deploy and verify the contract

1. Run `cp .env.example .env`

2. Specify `PRIVATE_KEY` and `BASE_RPC_URL` in `.env`

```bash
# may need to specify Etherscan API Key for certain network by --etherscan-api-key

# deploy UniswapV4MulticurveFeeHook to Base Sepolia
make deploy-base-sepolia-hook
# deploy SSLMilestoneUnlockHook to Base Sepolia
make deploy-base-sepolia-milestone-unlock-hook
# generate standard json input from the contract as `<CONTRACT_NAME>.json`
make verify <CONTRACT_ADDRESS> <CONTRACT_NAME>
```

### Create Token

1. Run `cp .env.example .env`

2. Specify `PRIVATE_KEY` and `BASE_RPC_URL` in `.env`

3. Specify addresses for `INTEGRATOR` and `CREATOR`, name and symbol for the token if necessary in `CreateTokenWithNewInitializer.s.sol`:

```solidity
// TODO: change to newly deployed Initializer address that adopts the new hook
address constant NEW_BASE_SEPOLIA_INITIALIZER = 0x6278211660DCfCc030521e8adBbc92b9630eEa50;
// TODO: change to desired integrator address
address constant INTEGRATOR = address(0);
// TODO: change to desired creator address
address constant CREATOR = address(0);
```

```bash
make create-token
```

### Unit Testing for Multicuve-related Hooks

1. Run `cp .env.example .env`

2. Inside `.env`
   - Put true for `IS_NUMERAIRE_NATIVE` if numeraire token will be native ETH (`true` will make `IS_ASSET_TOKEN0` always `false` given native ETH will always be `token0`)
   - Put true for `IS_ASSET_TOKEN0` if asset token is always token0

### Fork Testing

1. Run `cp .env.example .env`

2. Inside `.env`
   - Put a Tenderly Virtual testnet / Node RPC URL for `BASE_RPC_URL`

#### Test

For unlocking one SSL position via Milestone Unlock Hook

```bash
forge test --mt test_afterSwap_HitOneMilestone_unlockOnePosition -vvv
```

For buying asset with numeraire with ExactInput via Multicurve Fee Hook

```bash
forge test --mt test_beforeSwap_buyAssetExactIn_takesFeeFromNumeraire -vvv
```

## Troubleshooting

<details>

#### Failed to verify Doppler related contracts

Add this line to `remappings.txt`:

```
lib/doppler/:src/=lib/doppler/src/
```

Then continue the verification:

```bash
forge script ./script/BaseSepoliaMulticurveHook.s.sol --private-key $PRIVATE_KEY --rpc-url $BASE_SEPOLIA_RPC_URL --verify --broadcast --resume
```

</details>
