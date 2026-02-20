// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

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
import { BaseMulticurveMilestoneUnlockTest } from "test/BaseMulticurveMilestoneUnlockTest.sol";

error EmptyMilestonePositions();
error InvalidMilestonePositionsTickRange();
error InvalidMilestonePositionsTickBasedOnCurrentTick();
error MilestonePositionAlreadyWithdrawn();
error OnlyFromSSLMilestoneUnlockHook();

contract MilestoneUnlockUniswapV4MulticurveInitializerTest is BaseMulticurveMilestoneUnlockTest {
    // function setUp() public override {
    // super.setUp();

    // vm.prank(CREATOR);
    // (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

    // key = PoolKey({
    //     currency0: IS_ASSET_TOKEN0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
    //     currency1: IS_ASSET_TOKEN0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
    //     fee: FEE,
    //     tickSpacing: 8,
    //     hooks: IHooks(address(sslMilestoneUnlockHook))
    // });

    // // to simulate numeraire is available in other liquidity pools
    // // IMPORTANT: in production there should be enough numeraire tokens in PoolManager
    // deal(address(manager), 10 ether);
    // if (!IS_NUMERAIRE_NATIVE) {
    //     deal(numeraire, address(manager), 10 ether);
    //     deal(numeraire, FIRST_BUYER, 10 ether);
    // }
    // }

    function test_initialize_MilestonePositionsMinted() public view {
        MilestonePositionDetails[] memory MilestonePositionDetails =
            milestoneUnlockInitializer.getMilestonePositionDetails(asset);
        for (uint256 i; i < MilestonePositionDetails.length; i++) {
            int24 tickLower = IS_ASSET_TOKEN0 ? int24(uint24((i + 1) * 16_000)) : -int24(uint24((i + 2) * 16_000));
            assertEq(MilestonePositionDetails[i].tickLower, tickLower);
            assertEq(MilestonePositionDetails[i].tickUpper, tickLower + 16_000);
            assertEq(MilestonePositionDetails[i].salt, bytes32(uint256(keccak256(abi.encode(asset, i)))));
            assertEq(MilestonePositionDetails[i].recipient, UNLOCK_RECIPIENT);
            assertEq(MilestonePositionDetails[i].withdrawn, false);
        }
    }

    function test_initialize_RevertWhenEmptyMilestonePositions() public {
        MilestonePositionData[] memory milestonePositionsInfo = new MilestonePositionData[](0);
        bytes memory poolInitializerData =
            _prepareMilestoneUnlockUniswapV4MulticurveInitializerData(milestonePositionsInfo);
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = keccak256("test_initialize_RevertWhenEmptyMilestonePositions");

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(EmptyMilestonePositions.selector));
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
    }

    function test_initialize_RevertWhenInvalidMilestonePositionsTickRange() public {
        MilestonePositionData[] memory milestonePositionsInfo = _constructMilestonePositionInfo();
        milestonePositionsInfo[0].tickLower = milestonePositionsInfo[0].tickUpper;
        bytes memory poolInitializerData =
            _prepareMilestoneUnlockUniswapV4MulticurveInitializerData(milestonePositionsInfo);
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = keccak256("test_initialize_RevertWhenInvalidMilestonePositionsTickRange");

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(InvalidMilestonePositionsTickRange.selector));
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
    }

    function test_initialize_RevertWhenInvalidMilestonePositionsTickBasedOnCurrentTick() public {
        MilestonePositionData[] memory milestonePositionsInfo = _constructMilestonePositionInfo();
        milestonePositionsInfo[0].tickLower =
            IS_ASSET_TOKEN0 ? _getCurrentTick() - 8 : milestonePositionsInfo[0].tickLower;
        milestonePositionsInfo[0].tickUpper =
            IS_ASSET_TOKEN0 ? milestonePositionsInfo[0].tickUpper : _getCurrentTick() + 8;
        bytes memory poolInitializerData =
            _prepareMilestoneUnlockUniswapV4MulticurveInitializerData(milestonePositionsInfo);
        createParams.poolInitializerData = poolInitializerData;
        createParams.salt = keccak256("test_initialize_RevertWhenInvalidMilestonePositionsTickBasedOnCurrentTick");

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(InvalidMilestonePositionsTickBasedOnCurrentTick.selector));
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);
    }

    function test_unlockPosition_RevertWhenCallerIsNotSSLMilestoneUnlockHook() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(abi.encodeWithSelector(OnlyFromSSLMilestoneUnlockHook.selector));
        milestoneUnlockInitializer.unlockPosition(Currency.wrap(asset), Currency.wrap(numeraire), 0);
    }

    function test_unlockPosition_RevertWhenMilestonePositionAlreadyWithdrawn() public {
        // withdraw once
        uint256 triggerUnlockAmount = 20_000 ether;
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(triggerUnlockAmount));

        assertEq(milestoneUnlockInitializer.getMilestonePositionDetails(asset)[0].withdrawn, true);

        vm.prank(address(sslMilestoneUnlockHook));
        vm.expectRevert(abi.encodeWithSelector(MilestonePositionAlreadyWithdrawn.selector));
        milestoneUnlockInitializer.unlockPosition(Currency.wrap(asset), Currency.wrap(numeraire), 0);
    }
}
