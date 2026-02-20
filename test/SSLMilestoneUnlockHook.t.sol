// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import { console } from "forge-std/console.sol";

import { MilestonePositionDetails } from "src/MilestoneUnlockUniswapV4MulticurveInitializer.sol";
import { BaseMulticurveMilestoneUnlockTest } from "test/BaseMulticurveMilestoneUnlockTest.sol";

contract SSLMilestoneUnlockHookTest is BaseMulticurveMilestoneUnlockTest {
    function test_afterSwap_HitOneMilestone_unlockOnePosition() public {
        uint256 triggerUnlockAmount = 20_000 ether;

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256 assetBought;
        uint256 numeraireSold;

        // first buy as another user to pay the fee
        uint256 numeraireBalanceBeforeFirstBuyer = _getNumeraireBalance(FIRST_BUYER);
        (assetBought, numeraireSold) =
            buyWithNumeraire(FIRST_BUYER, key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));
        uint256 numeraireBalanceAfterFirstBuyer = _getNumeraireBalance(FIRST_BUYER);
        assertEq(
            numeraireBalanceAfterFirstBuyer,
            numeraireBalanceBeforeFirstBuyer - BUY_NUMERAIRE_AMOUNT,
            "numeraireBalanceAfterFirstBuyer"
        );

        uint256 numeraireBalanceBeforeRecipient = _getNumeraireBalance(UNLOCK_RECIPIENT);
        // second buy to trigger position unlock
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(triggerUnlockAmount));
        uint256 numeraireBalanceAfterRecipient = _getNumeraireBalance(UNLOCK_RECIPIENT);

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - triggerUnlockAmount, "numeraireBalanceAfter");
        assertEq(assetBalanceAfter, assetBalanceBefore + assetBought, "assetBalanceAfter");
        assertGt(numeraireBalanceAfterRecipient, numeraireBalanceBeforeRecipient, "numeraireBalanceAfterRecipient");

        // the first position should be unlocked
        MilestonePositionDetails[] memory MilestonePositionDetails =
            milestoneUnlockInitializer.getMilestonePositionDetails(asset);
        assertEq(MilestonePositionDetails[0].withdrawn, true);
        assertEq(MilestonePositionDetails[1].withdrawn, false);
    }

    function test_afterSwap_unlockMultiplePositions() public {
        uint256 triggerUnlockAmount = 120_000 ether;

        // first buy as another user to pay the fee
        buyWithNumeraire(FIRST_BUYER, key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));
        // console.log("current tick", _getCurrentTick());

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256 assetBought;
        uint256 numeraireSold;

        uint256 numeraireBalanceBeforeRecipient = _getNumeraireBalance(UNLOCK_RECIPIENT);
        // second buy to trigger position unlock
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(triggerUnlockAmount));
        uint256 numeraireBalanceAfterRecipient = _getNumeraireBalance(UNLOCK_RECIPIENT);

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - triggerUnlockAmount, "numeraireBalanceAfter");
        assertEq(assetBalanceAfter, assetBalanceBefore + assetBought, "assetBalanceAfter");
        assertGt(numeraireBalanceAfterRecipient, numeraireBalanceBeforeRecipient, "numeraireBalanceAfterRecipient");

        MilestonePositionDetails[] memory MilestonePositionDetails =
            milestoneUnlockInitializer.getMilestonePositionDetails(asset);
        assertEq(MilestonePositionDetails[0].withdrawn, true);
        assertEq(MilestonePositionDetails[1].withdrawn, true);
        assertEq(MilestonePositionDetails[2].withdrawn, false);

        console.log("current tick", _getCurrentTick());
    }
}
