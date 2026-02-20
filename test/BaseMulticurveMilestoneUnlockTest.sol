// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { ModuleState } from "doppler/src/Airlock.sol";
import { GovernanceFactory } from "doppler/src/governance/GovernanceFactory.sol";
import { WAD } from "doppler/src/types/Wad.sol";
import { sortBeneficiaries } from "doppler/test/integration/UniswapV4MigratorIntegration.t.sol";
import { console } from "forge-std/console.sol";

import {
    BeneficiaryData,
    Curve,
    InitData,
    MilestonePositionData,
    MilestonePositionDetails,
    MilestoneUnlockUniswapV4MulticurveInitializer
} from "src/MilestoneUnlockUniswapV4MulticurveInitializer.sol";
import { BaseMulticurveTest } from "test/BaseMulticurveTest.sol";
import { Constants } from "test/Constants.sol";

contract BaseMulticurveMilestoneUnlockTest is BaseMulticurveTest {
    using StateLibrary for IPoolManager;

    uint24 constant FEE = 10_000; // 1%
    uint256 constant FEE_DEMONIATOR = 1_000_000;

    address FIRST_BUYER = makeAddr("FIRST_BUYER");
    address UNLOCK_RECIPIENT = makeAddr("UNLOCK_RECIPIENT");

    function setUp() public virtual override {
        super.setUp();

        vm.prank(CREATOR);
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        key = PoolKey({
            currency0: IS_ASSET_TOKEN0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: IS_ASSET_TOKEN0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
            fee: FEE,
            tickSpacing: 8,
            hooks: IHooks(address(sslMilestoneUnlockHook))
        });

        // to simulate numeraire is available in other liquidity pools
        // IMPORTANT: in production there should be enough numeraire tokens in PoolManager
        deal(address(manager), 10 ether);
        deal(FIRST_BUYER, 10 ether);
        if (!IS_NUMERAIRE_NATIVE) {
            deal(numeraire, address(manager), 10 ether);
            deal(numeraire, FIRST_BUYER, 10 ether);
        }
    }

    /// @dev Override for custom deployment config
    function _deployContractsAndPrepareData(bytes32 salt) internal override {
        createParams.numTokensToSell = Constants.INITIAL_SUPPLY;
        createParams.initialSupply = Constants.INITIAL_SUPPLY;

        createParams.tokenFactory = _deployCloneERC20VotesFactory(AIRLOCK_OWNER);
        createParams.tokenFactoryData = _prepareTokenFactoryData(address(createParams.tokenFactory), salt);

        milestoneUnlockInitializer = _deploySSLMilestoneUnlockHook(address(manager));
        createParams.poolInitializer = milestoneUnlockInitializer;
        createParams.poolInitializerData = _prepareMilestoneUnlockUniswapV4MulticurveInitializerData();

        createParams.liquidityMigrator = _deployNoOpMigrator(AIRLOCK_OWNER);
        createParams.governanceFactory = _deployGovernanceFactory(AIRLOCK_OWNER);
        createParams.governanceFactoryData = _prepareGovernanceFactoryData();
    }

    function _deploySSLMilestoneUnlockHook(address poolManager)
        internal
        returns (MilestoneUnlockUniswapV4MulticurveInitializer milestoneUnlockMulticurveInitializer)
    {
        milestoneUnlockMulticurveInitializer = new MilestoneUnlockUniswapV4MulticurveInitializer(
            address(airlock), IPoolManager(poolManager), sslMilestoneUnlockHook
        );
        deployCodeTo(
            "SSLMilestoneUnlockHook",
            abi.encode(address(poolManager), address(milestoneUnlockMulticurveInitializer)),
            address(sslMilestoneUnlockHook)
        );
        address[] memory modules = new address[](1);
        modules[0] = address(milestoneUnlockMulticurveInitializer);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.PoolInitializer;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
    }

    function _prepareMilestoneUnlockUniswapV4MulticurveInitializerData(MilestonePositionData[] memory milestonePositionsInfo)
        internal
        view
        returns (bytes memory poolInitializerData)
    {
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
        beneficiaries[0] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
        beneficiaries[1] = BeneficiaryData({ beneficiary: INTEGRATOR, shares: 0.45e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: CREATOR, shares: 0.5e18 });
        beneficiaries = sortBeneficiaries(beneficiaries);

        poolInitializerData = abi.encode(
            InitData({
                fee: FEE,
                tickSpacing: 8,
                curves: curves,
                beneficiaries: beneficiaries,
                milestonePositionsInfo: milestonePositionsInfo
            })
        );
    }

    function _prepareMilestoneUnlockUniswapV4MulticurveInitializerData()
        internal
        view
        returns (bytes memory poolInitializerData)
    {
        return _prepareMilestoneUnlockUniswapV4MulticurveInitializerData(_constructMilestonePositionInfo());
    }

    function _constructMilestonePositionInfo()
        internal
        view
        returns (MilestonePositionData[] memory milestonePositionsInfo)
    {
        milestonePositionsInfo = new MilestonePositionData[](3);
        for (uint256 i; i < 3; ++i) {
            int24 tickLower = IS_ASSET_TOKEN0 ? int24(uint24((i + 1) * 16_000)) : -int24(uint24((i + 2) * 16_000));
            milestonePositionsInfo[i].tickLower = tickLower;
            milestonePositionsInfo[i].tickUpper = tickLower + 16_000;
            milestonePositionsInfo[i].amount = 100_000;
            milestonePositionsInfo[i].recipient = UNLOCK_RECIPIENT;
            // console.log("tickLower", tickLower);
            // console.log("tickUpper", tickLower + 16_000);
        }
    }

    function _feeAmount(uint256 amount) internal pure returns (uint256) {
        return amount * FEE / FEE_DEMONIATOR;
    }

    function _getCurrentTick() internal view returns (int24) {
        (uint160 sqrtPrice,,,) = manager.getSlot0(key.toId());
        return TickMath.getTickAtSqrtPrice(sqrtPrice);
    }
}
