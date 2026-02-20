// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Airlock, CreateParams } from "doppler/src/Airlock.sol";
import { IGovernanceFactory, ILiquidityMigrator, IPoolInitializer, ITokenFactory } from "doppler/src/Airlock.sol";
import { BeneficiaryData, Curve, InitData } from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { WAD } from "doppler/src/types/Wad.sol";
import { sortBeneficiaries } from "doppler/test/integration/UniswapV4MigratorIntegration.t.sol";
import { Script } from "forge-std/Script.sol";
import { console } from "forge-std/console.sol";

import { Constants } from "script/Constants.sol";

interface IAirlock {
    function create(CreateParams calldata createData)
        external
        returns (address asset, address pool, address governance, address timelock, address migrationPool);
}

contract CreateTokenScript is Script, Constants {
    CreateParams createParams;

    address constant BASE_SEPOLIA_AIRLOCK_OWNER = 0x0abCf819FD57C9f0141628410fFC273405E44426;

    address constant BASE_SEPOLIA_TOKEN_FACTORY = 0xbf4Ca4D527c9760A884df31292f72E9AcA503045;
    address constant BASE_SEPOLIA_NO_OP_MIGRATOR = 0xF11066abbd329ac4bBA39455340539322C222eb0;
    address constant BASE_SEPOLIA_GOVERNANCE_FACTORY = 0x9dBFaaDC8c0cB2c34bA698DD9426555336992e20;

    // TODO: change to newly deployed Initializer address that adopts the new hook
    address constant NEW_BASE_SEPOLIA_INITIALIZER = 0x6278211660DCfCc030521e8adBbc92b9630eEa50;
    // TODO: change to desired integrator address
    address constant INTEGRATOR = address(0);
    // TODO: change to desired creator address
    address constant CREATOR = address(0);

    string constant TOKEN_NAME = "Test Token";
    string constant TOKEN_SYMBOL = "TEST";
    string constant TOKEN_URI = "TOKEN_URI";

    uint24 constant POOL_FEE = 0;
    uint256 constant NUM_TOKENS_TO_SELL = 1e23;
    uint256 constant INITIAL_SUPPLY = 1e23;

    function setUp() public virtual {
        require(INTEGRATOR != address(0), "INTEGRATOR is not set");
        require(CREATOR != address(0), "CREATOR is not set");
        require(POOL_FEE == 0, "POOL_FEE must be 0 to adopt new fee hook");

        createParams.tokenFactory = ITokenFactory(BASE_SEPOLIA_TOKEN_FACTORY);
        createParams.tokenFactoryData =
            abi.encode(TOKEN_NAME, TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0), TOKEN_URI);

        createParams.poolInitializer = IPoolInitializer(NEW_BASE_SEPOLIA_INITIALIZER);
        createParams.poolInitializerData = _prepareUniswapV4MulticurveInitializerData(INTEGRATOR, CREATOR, POOL_FEE);
        createParams.numTokensToSell = NUM_TOKENS_TO_SELL;
        createParams.initialSupply = INITIAL_SUPPLY;

        createParams.liquidityMigrator = ILiquidityMigrator(BASE_SEPOLIA_NO_OP_MIGRATOR);
        createParams.governanceFactory = IGovernanceFactory(BASE_SEPOLIA_GOVERNANCE_FACTORY);
        createParams.governanceFactoryData = abi.encode(TOKEN_NAME, 7200, 50_400, 0);
    }

    function run() public {
        vm.startBroadcast();
        (address asset,,,,) = IAirlock(BASE_SEPOLIA_AIRLOCK).create(createParams);
        console.log("Token deployed at: %s!", asset);
        vm.stopBroadcast();
    }

    function _prepareUniswapV4MulticurveInitializerData(
        address integrator,
        address creator,
        uint24 fee
    ) internal pure returns (bytes memory poolInitializerData) {
        Curve[] memory curves = new Curve[](10);
        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        // Beneficiary split
        // - 5% to Doppler (dopplerBeneficiary) - required by protocol
        // - 45% to integrator (INTEGRATOR_ADDRESS)
        // - 50% to token creator (msg.sender)
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](3);
        beneficiaries[0] = BeneficiaryData({ beneficiary: BASE_SEPOLIA_AIRLOCK_OWNER, shares: 0.05e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: integrator, shares: 0.45e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: creator, shares: 0.5e18 });
        beneficiaries = sortBeneficiaries(beneficiaries);

        poolInitializerData =
            abi.encode(InitData({ fee: fee, tickSpacing: 8, curves: curves, beneficiaries: beneficiaries }));
    }
}
