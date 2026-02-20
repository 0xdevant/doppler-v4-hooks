// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import { IHooks } from "@v4-core/interfaces/IHooks.sol";
import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { CustomRevert } from "@v4-core/libraries/CustomRevert.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { StateLibrary } from "@v4-core/libraries/StateLibrary.sol";
import { Currency } from "@v4-core/types/Currency.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IV4Quoter } from "@v4-periphery/lens/V4Quoter.sol";
import { ModuleState } from "doppler/src/Airlock.sol";
import { GovernanceFactory } from "doppler/src/governance/GovernanceFactory.sol";
import {
    BeneficiaryData,
    Curve,
    UniswapV4MulticurveInitializer
} from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { WAD } from "doppler/src/types/Wad.sol";
import { sortBeneficiaries } from "doppler/test/integration/UniswapV4MigratorIntegration.t.sol";

import { Airlock, BaseMulticurveTest } from "test/BaseMulticurveTest.sol";

error FeeMustBeZero();

contract UniswapV4MulticurveInitializerFeeHookTest is BaseMulticurveTest {
    function setUp() public override {
        super.setUp();

        vm.prank(CREATOR);
        (asset, pool, governance, timelock, migrationPool) = airlock.create(createParams);

        key = PoolKey({
            currency0: IS_ASSET_TOKEN0 ? Currency.wrap(asset) : Currency.wrap(numeraire),
            currency1: IS_ASSET_TOKEN0 ? Currency.wrap(numeraire) : Currency.wrap(asset),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(multicurveFeeHook))
        });

        // to simulate numeraire is available in other liquidity pools
        // IMPORTANT: in production there should be enough numeraire tokens in PoolManager
        deal(address(manager), 10 ether);
        if (!IS_NUMERAIRE_NATIVE) deal(numeraire, address(manager), 10 ether);
    }

    function test_beforeSwap_buyAssetExactIn_takesFeeFromNumeraire() public {
        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));
        vm.snapshotGasLastCall("default beforeSwap take fee to 3 beneficiaries");

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - BUY_NUMERAIRE_AMOUNT);
        assertEq(assetBalanceAfter, assetBalanceBefore + assetBought);

        // ensure beneficiaries received the correct fee respect to their shares
        uint256 feeAmount = BUY_NUMERAIRE_AMOUNT * HOOK_FEE_WAD / WAD;
        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(_getNumeraireBalance(beneficiaries[i].beneficiary), feeAmount * shares / WAD);
        }

        // console.log("asset balance before", assetBalanceBefore);
        // console.log("asset balance after", assetBalanceAfter);
        // console.log("eth balance before", ethBalanceBefore);
        // console.log("eth balance after", ethBalanceAfter);
    }

    function test_beforeSwap_buyAssetExactIn_takesFeeFromNumeraire_noBalanceInPoolManager() public {
        deal(address(manager), 0);
        if (!IS_NUMERAIRE_NATIVE) deal(numeraire, address(manager), 0 ether);

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - BUY_NUMERAIRE_AMOUNT);
        assertEq(assetBalanceAfter, assetBalanceBefore + assetBought);

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < beneficiaries.length; i++) {
            assertEq(_getNumeraireBalance(beneficiaries[i].beneficiary), 0);
        }
    }

    function testFuzz_beforeSwap_buyAssetExactIn_takesFeeFromNumeraire(uint256 buyEthAmount) public {
        buyEthAmount = bound(buyEthAmount, 0.01 ether, 10 ether);

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(buyEthAmount));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - buyEthAmount);
        assertEq(assetBalanceAfter, assetBalanceBefore + assetBought);

        // ensure beneficiaries received the correct fee respect to their shares
        uint256 feeAmount = buyEthAmount * HOOK_FEE_WAD / WAD;
        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            // account for precision loss due to the fuzzing inputs
            assertApproxEqRelDecimal(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeAmount * shares / WAD,
                0.001e18, // 0.1% precision loss
                18
            );
        }
    }

    // function testFuzz_beforeSwap_randomBeneficiaries_buyAssetExactIn_takesFeeFromNumeraire(
    //     uint256 buyEthAmount,
    //     uint256 beneficiariiesShare0,
    //     uint256 beneficiariiesShare1,
    //     uint256 beneficiariiesShare2
    // ) public {
    //     buyEthAmount = bound(buyEthAmount, 0.01 ether, 10 ether);
    //     // beneficiariiesShare0 = bound(beneficiariiesShare0, 1e18, TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER);
    //     // beneficiariiesShare1 =
    //     //     bound(beneficiariiesShare1, 1e18, TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER - beneficiariiesShare0);
    //     // beneficiariiesShare2 = bound(
    //     //     beneficiariiesShare2, 1e18, TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER - beneficiariiesShare0 - beneficiariiesShare1
    //     // );
    //     vm.assume(
    //         beneficiariiesShare0 + beneficiariiesShare1 + beneficiariiesShare2 == TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER
    //     );

    //     uint256[] memory sharesOtherThanAirlockOwner = new uint256[](3);
    //     sharesOtherThanAirlockOwner[0] = beneficiariiesShare0;
    //     sharesOtherThanAirlockOwner[1] = beneficiariiesShare1;
    //     sharesOtherThanAirlockOwner[2] = beneficiariiesShare2;
    //     (address newAsset, PoolKey memory key) =
    //         _createWithNewInitializerData(sharesOtherThanAirlockOwner, keccak256("test_salt"));

    //     uint256 assetBalanceBefore = IERC20(newAsset).balanceOf(address(this));
    //     uint256 ethBalanceBefore = address(this).balance;
    //     uint256 assetBought;
    //     uint256 numeraireSold;
    //     // buy asset with numeraire
    //     (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(buyEthAmount));

    //     uint256 ethBalanceAfter = address(this).balance;
    //     uint256 assetBalanceAfter = IERC20(newAsset).balanceOf(address(this));

    //     assertEq(ethBalanceAfter, ethBalanceBefore - buyEthAmount);
    //     assertEq(assetBalanceAfter, assetBalanceBefore + assetBought);

    //     // ensure beneficiaries received the correct fee respect to their shares
    //     uint256 feeAmount = buyEthAmount * HOOK_FEE_WAD / WAD;
    //     BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(newAsset);

    //     for (uint256 i; i < beneficiaries.length; i++) {
    //         uint256 shares = beneficiaries[i].shares;
    //         // account for precision loss due to the fuzzing inputs
    //         assertApproxEqRelDecimal(
    //             beneficiaries[i].beneficiary.balance,
    //             feeAmount * shares / WAD,
    //             0.001e18, // 0.1% precision loss
    //             18
    //         );
    //     }
    // }

    function test_beforeSwap_sellAssetExactOut_takesFeeFromNumeraire() public {
        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);
        uint256 sellNumeraireAmount = 0.3 ether;

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        (tokenSold, numeraireBought) = sellWithAsset(key, IS_ASSET_TOKEN0, int256(sellNumeraireAmount));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBought, sellNumeraireAmount);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = sellNumeraireAmount * HOOK_FEE_WAD / WAD;
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }
    }

    function testFuzz_beforeSwap_sellAssetExactOut_takesFeeFromNumeraire(
        uint256 buyEthAmount,
        uint256 sellNumeraireAmount
    ) public {
        buyEthAmount = bound(buyEthAmount, 0.01 ether, 10 ether);
        sellNumeraireAmount = bound(sellNumeraireAmount, 0.008 ether, buyEthAmount * 8 / 10); // 80% of buyEthAmount

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(buyEthAmount));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        (tokenSold, numeraireBought) = sellWithAsset(key, IS_ASSET_TOKEN0, int256(sellNumeraireAmount));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(numeraireBought, sellNumeraireAmount);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = sellNumeraireAmount * HOOK_FEE_WAD / WAD;
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertApproxEqRelDecimal(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD,
                0.001e18, // 0.1% precision loss
                18
            );
        }
    }

    function test_afterSwap_sellAssetExactIn_takesFeeFromNumeraire() public {
        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        // sell asset for numeraire
        (tokenSold, numeraireBought) = sellWithAsset(key, IS_ASSET_TOKEN0, -int256(SELL_ASSET_AMOUNT));
        vm.snapshotGasLastCall("default afterSwap take fee to 3 beneficiaries");

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = _feeAmount(numeraireBought, false);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }

        // console.log("asset balance before", assetBalanceBefore);
        // console.log("asset balance after", assetBalanceAfter);
        // console.log("eth balance before", ethBalanceBefore);
        // console.log("eth balance after", ethBalanceAfter);
    }

    function test_afterSwap_sellAssetExactIn_takesFeeFromNumeraire_noBalanceInPoolManager() public {
        deal(address(manager), 0);
        if (!IS_NUMERAIRE_NATIVE) deal(numeraire, address(manager), 0 ether);

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        // sell asset for numeraire
        (tokenSold, numeraireBought) = sellWithAsset(key, IS_ASSET_TOKEN0, -int256(SELL_ASSET_AMOUNT));
        vm.snapshotGasLastCall("default afterSwap take fee to 3 beneficiaries");

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = _feeAmount(numeraireBought, false);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }
    }

    function test_afterSwap_sellAssetExactIn_takesFeeFromNumeraire_NativeNumeraire() public {
        // set respective configs ans create new asset with native numeraire
        IS_NUMERAIRE_NATIVE = true;
        IS_ASSET_TOKEN0 = false;
        numeraire = address(0);

        createParams.numeraire = address(0);
        createParams.salt = keccak256("test_native_numeraire_salt");
        address newAsset;
        (newAsset,,,,) = airlock.create(createParams);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(newAsset),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(multicurveFeeHook))
        });

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(newAsset);

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        // sell asset for numeraire
        (tokenSold, numeraireBought) =
            sellWithAsset(newAsset, address(this), key, IS_ASSET_TOKEN0, -int256(SELL_ASSET_AMOUNT));
        vm.snapshotGasLastCall("default afterSwap take fee to 3 beneficiaries");

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = _feeAmount(numeraireBought, false);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }
    }

    function testFuzz_afterSwap_sellAssetExactIn_takesFeeFromNumeraire(
        uint256 buyEthAmount,
        uint256 sellAssetAmount
    ) public {
        buyEthAmount = bound(buyEthAmount, 0.01 ether, 10 ether);
        sellAssetAmount = bound(sellAssetAmount, 0.008 ether, buyEthAmount * 8 / 10); // 80% of buyEthAmount

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        // first buy asset with numeraire
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(buyEthAmount));

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 tokenSold;
        uint256 numeraireBought;
        // sell asset for numeraire
        (tokenSold, numeraireBought) = sellWithAsset(key, IS_ASSET_TOKEN0, -int256(sellAssetAmount));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBalanceAfter, assetBalanceBefore - tokenSold);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore + numeraireBought);

        uint256 feeAmount = _feeAmount(numeraireBought, false);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertApproxEqRelDecimal(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD,
                0.001e18, // 0.1% precision loss
                18
            );
        }
    }

    function test_afterSwap_buyAssetExactOut_takesFeeFromNumeraire() public {
        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);
        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, int256(BUY_ASSET_AMOUNT));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBought, BUY_ASSET_AMOUNT);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - numeraireSold);
        assertEq(assetBalanceAfter, assetBalanceBefore + BUY_ASSET_AMOUNT);

        uint256 feeAmount = _feeAmount(numeraireSold, true);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }
    }

    function test_afterSwap_buyAssetExactOut_takesFeeFromNumeraire_NativeNumeraire() public {
        // set respective configs ans create new asset with native numeraire
        IS_NUMERAIRE_NATIVE = true;
        IS_ASSET_TOKEN0 = false;
        numeraire = address(0);

        createParams.numeraire = address(0);
        createParams.salt = keccak256("test_native_numeraire_salt");
        address newAsset;
        (newAsset,,,,) = airlock.create(createParams);
        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(newAsset),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(multicurveFeeHook))
        });

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(newAsset);
        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, int256(BUY_ASSET_AMOUNT));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBought, BUY_ASSET_AMOUNT);
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - numeraireSold);
        assertEq(assetBalanceAfter, assetBalanceBefore + BUY_ASSET_AMOUNT);

        uint256 feeAmount = _feeAmount(numeraireSold, true);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertEq(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD
            );
        }
    }

    function testFuzz_afterSwap_buyAssetExactOut_takesFeeFromNumeraire(uint256 buyAssetAmount) public {
        buyAssetAmount = bound(buyAssetAmount, 0.01 ether, 10 ether);

        BeneficiaryData[] memory beneficiaries = initializer.getBeneficiaries(asset);

        (uint256 assetBalanceBefore, uint256 numeraireBalanceBefore) = _getBalances(key);
        uint256[] memory feeRecipientsBalanceBefore = new uint256[](3);
        for (uint256 i; i < beneficiaries.length; i++) {
            feeRecipientsBalanceBefore[i] = _getNumeraireBalance(beneficiaries[i].beneficiary);
        }

        uint256 assetBought;
        uint256 numeraireSold;
        // buy asset with numeraire
        (assetBought, numeraireSold) = buyWithNumeraire(key, IS_ASSET_TOKEN0, int256(buyAssetAmount));

        (uint256 assetBalanceAfter, uint256 numeraireBalanceAfter) = _getBalances(key);
        assertEq(assetBought, uint256(buyAssetAmount));
        assertEq(numeraireBalanceAfter, numeraireBalanceBefore - numeraireSold);
        assertEq(assetBalanceAfter, assetBalanceBefore + uint256(buyAssetAmount));

        uint256 feeAmount = _feeAmount(numeraireSold, true);
        for (uint256 i; i < beneficiaries.length; i++) {
            uint256 shares = beneficiaries[i].shares;
            assertApproxEqRelDecimal(
                _getNumeraireBalance(beneficiaries[i].beneficiary),
                feeRecipientsBalanceBefore[i] + feeAmount * shares / WAD,
                0.001e18, // 0.1% precision loss
                18
            );
        }
    }

    function test_beforeInitialize_revertsWhenFeeIsNotZero() public {
        // pass 1 as fee
        createParams.poolInitializerData = _prepareUniswapV4MulticurveInitializerData(INTEGRATOR, CREATOR, 1);
        createParams.salt = keccak256("test_salt");

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(multicurveFeeHook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(FeeMustBeZero.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        airlock.create(createParams);
    }

    function test_gas_benchmark_take_fee_to_beneficiaries() public {
        uint256 smallSharesLength = 4;
        uint256[] memory smallShares = new uint256[](smallSharesLength);
        for (uint256 i; i < smallSharesLength; ++i) {
            smallShares[i] = TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER / smallSharesLength;
        }
        (, key) = _createWithNewInitializerData(smallShares, keccak256("gas_benchmark_salt_small"));
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));
        vm.snapshotGasLastCall(
            string.concat(
                "gas-benchmark: beforeSwap take fee to ", vm.toString(smallSharesLength + 1), " beneficiaries"
            )
        );

        uint256 bigSharesLength = 8;
        uint256[] memory bigShares = new uint256[](bigSharesLength);
        for (uint256 i; i < bigSharesLength; ++i) {
            bigShares[i] = TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER / bigSharesLength;
        }
        (, key) = _createWithNewInitializerData(bigShares, keccak256("gas_benchmark_salt_big"));
        buyWithNumeraire(key, IS_ASSET_TOKEN0, -int256(BUY_NUMERAIRE_AMOUNT));
        vm.snapshotGasLastCall(
            string.concat("gas-benchmark: beforeSwap take fee to ", vm.toString(bigSharesLength + 1), " beneficiaries")
        );
    }

    /* HELPER METHODS */
    function _createWithNewInitializerData(
        uint256[] memory sharesOtherThanAirlockOwner,
        bytes32 salt
    ) internal returns (address newAsset, PoolKey memory key) {
        createParams.poolInitializerData = _prepareUniswapV4MulticurveInitializerData(sharesOtherThanAirlockOwner);
        createParams.salt = salt;

        (newAsset,,,,) = airlock.create(createParams);
        key = PoolKey({
            currency0: IS_ASSET_TOKEN0 ? Currency.wrap(newAsset) : Currency.wrap(numeraire),
            currency1: IS_ASSET_TOKEN0 ? Currency.wrap(numeraire) : Currency.wrap(newAsset),
            fee: 0,
            tickSpacing: 8,
            hooks: IHooks(address(multicurveFeeHook))
        });
    }

    function _feeAmount(uint256 amount, bool isExactOut) internal pure returns (uint256) {
        if (isExactOut) {
            return amount * 100 / 110 * HOOK_FEE_WAD / WAD; // divide by 1.1 since the passed amount is before duducting fee
        } else {
            return amount * 100 / 90 * HOOK_FEE_WAD / WAD; // divide by 0.9 since the passed amount is after deducting fee
        }
    }

    /// @dev Override for custom deployment config
    function _deployContractsAndPrepareData(bytes32 salt) internal override {
        createParams.numTokensToSell = INITIAL_SUPPLY;
        createParams.initialSupply = INITIAL_SUPPLY;

        createParams.tokenFactory = _deployCloneERC20VotesFactory(AIRLOCK_OWNER);
        createParams.tokenFactoryData = _prepareTokenFactoryData(address(createParams.tokenFactory), salt);

        initializer = _deployUniswapV4MulticurveInitializerFeeHook(address(manager));
        createParams.poolInitializer = initializer;
        createParams.poolInitializerData = _prepareUniswapV4MulticurveInitializerData(INTEGRATOR, CREATOR, 0);

        createParams.liquidityMigrator = _deployNoOpMigrator(AIRLOCK_OWNER);
        createParams.governanceFactory = _deployGovernanceFactory(AIRLOCK_OWNER);
        createParams.governanceFactoryData = _prepareGovernanceFactoryData();
    }

    function _deployUniswapV4MulticurveInitializerFeeHook(address poolManager)
        internal
        returns (UniswapV4MulticurveInitializer multicurveInitializer)
    {
        multicurveInitializer = new UniswapV4MulticurveInitializer(
            address(airlock), IPoolManager(poolManager), multicurveFeeHook
        );
        deployCodeTo(
            "UniswapV4MulticurveInitializerFeeHook",
            abi.encode(address(poolManager), address(multicurveInitializer), HOOK_FEE_WAD),
            address(multicurveFeeHook)
        );
        address[] memory modules = new address[](1);
        modules[0] = address(multicurveInitializer);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.PoolInitializer;
        vm.prank(AIRLOCK_OWNER);
        airlock.setModuleState(modules, states);
    }
}
