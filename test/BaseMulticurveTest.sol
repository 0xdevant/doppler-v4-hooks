// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IPoolManager } from "@v4-core/interfaces/IPoolManager.sol";
import { Hooks } from "@v4-core/libraries/Hooks.sol";
import { TickMath } from "@v4-core/libraries/TickMath.sol";
import { PoolSwapTest } from "@v4-core/test/PoolSwapTest.sol";
import { TestERC20 } from "@v4-core/test/TestERC20.sol";
import { BalanceDelta } from "@v4-core/types/BalanceDelta.sol";
import { PoolKey } from "@v4-core/types/PoolKey.sol";
import { IAllowanceTransfer } from "doppler/lib/v4-periphery/lib/permit2/src/interfaces/IAllowanceTransfer.sol";
import { DeployPermit2 } from "doppler/lib/v4-periphery/lib/permit2/test/utils/DeployPermit2.sol";
import { Deployers } from "doppler/lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import { IPositionManager } from "doppler/lib/v4-periphery/src/interfaces/IPositionManager.sol";
import { Deploy } from "doppler/lib/v4-periphery/test/shared/Deploy.sol";
import { Airlock, CreateParams, ModuleState } from "doppler/src/Airlock.sol";
import { GovernanceFactory } from "doppler/src/governance/GovernanceFactory.sol";
import {
    BeneficiaryData,
    Curve,
    InitData,
    UniswapV4MulticurveInitializer
} from "doppler/src/initializers/UniswapV4MulticurveInitializer.sol";
import { NoOpMigrator } from "doppler/src/migrators/NoOpMigrator.sol";
import { DERC20 } from "doppler/src/tokens/DERC20.sol";
import { WAD } from "doppler/src/types/Wad.sol";
import {
    CloneERC20VotesFactory,
    prepareCloneERC20VotesFactoryData
} from "doppler/test/integration/CloneERC20VotesFactory.t.sol";
import { sortBeneficiaries } from "doppler/test/integration/UniswapV4MigratorIntegration.t.sol";
import { console } from "forge-std/console.sol";

import { MilestoneUnlockUniswapV4MulticurveInitializer } from "src/MilestoneUnlockUniswapV4MulticurveInitializer.sol";
import { SSLMilestoneUnlockHook } from "src/SSLMilestoneUnlockHook.sol";
import { UniswapV4MulticurveInitializerFeeHook } from "src/UniswapV4MulticurveInitializerFeeHook.sol";
import { Constants } from "test/Constants.sol";

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

abstract contract BaseMulticurveTest is Deployers, DeployPermit2, Constants {
    uint256 constant TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER = 0.95e18; // 95% total shares excluding airlock owner's 5% shares
    uint256 constant HOOK_FEE_WAD = 0.1e18; // 10% fee

    address constant alwaysToken0Address = address(0x0000000000000000000000000000000000000011); // address small enough to be always token0
    address constant alwaysToken1Address = address(0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF); // address large enough to be always token1

    address AIRLOCK_OWNER = makeAddr("AIRLOCK_OWNER");
    address INTEGRATOR = makeAddr("INTEGRATOR");
    address CREATOR = makeAddr("CREATOR");

    // is numeraire native ETH? if no then numeraire MUST be token1
    bool internal IS_NUMERAIRE_NATIVE = vm.envOr("IS_NUMERAIRE_NATIVE", false);
    // IMPORTANT: this will be changed automatically if numeraire is native ETH, changing this to `false` will require updating the contract logic
    bool internal IS_ASSET_TOKEN0 = vm.envOr("IS_ASSET_TOKEN0", true);

    IAllowanceTransfer public permit2;
    IPositionManager public positionManager;
    Airlock public airlock;

    // to be used to call `getBeneficiaries`
    UniswapV4MulticurveInitializer public initializer;
    MilestoneUnlockUniswapV4MulticurveInitializer public milestoneUnlockInitializer;

    /// @dev Parameters used to create the asset in the Airlock, must be filled by the inheriting contract
    CreateParams internal createParams;

    address internal asset;
    address internal pool;
    address internal governance;
    address internal timelock;
    address internal migrationPool;

    address internal numeraire;

    UniswapV4MulticurveInitializerFeeHook internal multicurveFeeHook = UniswapV4MulticurveInitializerFeeHook(
        payable(address(
                uint160(
                    Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                        | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
                ) ^ (0x4444 << 144)
            ))
    );

    SSLMilestoneUnlockHook internal sslMilestoneUnlockHook = SSLMilestoneUnlockHook(
        payable(address(
                uint160(
                    Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                        | Hooks.AFTER_SWAP_FLAG
                ) ^ (0x4444 << 144)
            ))
    );

    function setUp() public virtual {
        if (IS_NUMERAIRE_NATIVE) {
            IS_ASSET_TOKEN0 = false;
        }
        console.log("-------------- CURRENT CONFIG ------------------");
        console.log("IS_NUMERAIRE_NATIVE", IS_NUMERAIRE_NATIVE);
        console.log("IS_ASSET_TOKEN0", IS_ASSET_TOKEN0);
        console.log("\n");

        numeraire = IS_ASSET_TOKEN0 ? alwaysToken1Address : IS_NUMERAIRE_NATIVE ? address(0) : alwaysToken0Address;

        if (!IS_NUMERAIRE_NATIVE) _deployNumeraire();
        deployFreshManagerAndRouters();
        permit2 = IAllowanceTransfer(deployPermit2());
        positionManager = Deploy.positionManager(
            address(manager), address(permit2), type(uint256).max, address(0), address(0), hex"beef"
        );
        airlock = new Airlock(AIRLOCK_OWNER);

        _deployContractsAndPrepareData(keccak256("test salt"));
    }

    /// @dev Override for custom deployment config on token factory, pool initializer, liquidity migrator, and governance factory
    function _deployContractsAndPrepareData(bytes32 salt) internal virtual { }

    function _deployNumeraire() internal {
        deployCodeTo("TestERC20.sol:TestERC20", abi.encode(1e48), numeraire);
        createParams.numeraire = numeraire;
    }

    // this helper function is put here to solve implicit conversion compile errors
    function _deployCloneERC20VotesFactory(address airlockOwner) internal returns (CloneERC20VotesFactory factory) {
        factory = new CloneERC20VotesFactory(address(airlock));
        address[] memory modules = new address[](1);
        modules[0] = address(factory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.TokenFactory;
        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function _prepareTokenFactoryData(address, bytes32) internal pure returns (bytes memory data) {
        // address computedAsset = vm.computeCreate2Address(
        //     salt,
        //     keccak256(
        //         abi.encodePacked(
        //             type(DERC20).creationCode,
        //             abi.encode(
        //                 TOKEN_NAME, TOKEN_SYMBOL, TOKEN_INITIAL_SUPPLY, airlock, airlock, 0, 0, new address[](0), new uint256[](0), TOKEN_URI
        //             )
        //         )
        //     ),
        //     factory
        // );

        data = abi.encode(TOKEN_NAME, TOKEN_SYMBOL, 0, 0, new address[](0), new uint256[](0), TOKEN_URI);
    }

    function _prepareUniswapV4MulticurveInitializerData(
        address integrator,
        address creator,
        uint24 fee
    ) internal view returns (bytes memory poolInitializerData) {
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
        beneficiaries[1] = BeneficiaryData({ beneficiary: integrator, shares: 0.45e18 });
        beneficiaries[2] = BeneficiaryData({ beneficiary: creator, shares: 0.5e18 });
        beneficiaries = sortBeneficiaries(beneficiaries);

        poolInitializerData =
            abi.encode(InitData({ fee: fee, tickSpacing: 8, curves: curves, beneficiaries: beneficiaries }));
    }

    function _prepareUniswapV4MulticurveInitializerData(uint256[] memory sharesOtherThanAirlockOwner)
        internal
        returns (bytes memory poolInitializerData)
    {
        Curve[] memory curves = new Curve[](10);
        for (uint256 i; i < 10; ++i) {
            curves[i].tickLower = int24(uint24(0 + i * 16_000));
            curves[i].tickUpper = 240_000;
            curves[i].numPositions = 10;
            curves[i].shares = WAD / 10;
        }

        uint256 len = sharesOtherThanAirlockOwner.length;
        BeneficiaryData[] memory beneficiaries = new BeneficiaryData[](len + 1);
        uint256 totalShares;
        for (uint256 i; i < len; i++) {
            totalShares += sharesOtherThanAirlockOwner[i];
            beneficiaries[i] = BeneficiaryData({
                beneficiary: makeAddr(string.concat("Beneficiary", vm.toString(i))),
                shares: uint96(sharesOtherThanAirlockOwner[i])
            });
        }
        // add airlock owner's shares at the end
        beneficiaries[len] = BeneficiaryData({ beneficiary: airlock.owner(), shares: 0.05e18 });
        require(
            totalShares == TOTAL_SHARES_EXCLUDE_AIRLOCK_OWNER,
            "Total shares must be 0.95e18 after excluding airlock owner's shares"
        );

        beneficiaries = sortBeneficiaries(beneficiaries);
        poolInitializerData =
            abi.encode(InitData({ fee: 0, tickSpacing: 8, curves: curves, beneficiaries: beneficiaries }));
    }

    function _deployNoOpMigrator(address airlockOwner) internal returns (NoOpMigrator noOpMigrator) {
        noOpMigrator = new NoOpMigrator(address(airlock));
        address[] memory modules = new address[](1);
        modules[0] = address(noOpMigrator);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.LiquidityMigrator;
        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function _deployGovernanceFactory(address airlockOwner) internal returns (GovernanceFactory factory) {
        factory = new GovernanceFactory(address(airlock));
        address[] memory modules = new address[](1);
        modules[0] = address(factory);
        ModuleState[] memory states = new ModuleState[](1);
        states[0] = ModuleState.GovernanceFactory;
        vm.prank(airlockOwner);
        airlock.setModuleState(modules, states);
    }

    function _prepareGovernanceFactoryData() internal pure returns (bytes memory) {
        return abi.encode("Test Token", 7200, 50_400, 0);
    }

    /* TEST METHODS */
    /// @dev Buys a given amount of asset tokens with numeraire
    function buyWithNumeraire(
        address from,
        PoolKey memory poolKey,
        bool isToken0,
        int256 amount
    ) public returns (uint256, uint256) {
        // Negative means exactIn, positive means exactOut.
        uint256 mintAmount = amount < 0 ? uint256(-amount) : uint256(amount) * 2; // * 2 to skip computing the amount needed for exactOut
        vm.startPrank(from);
        if (!IS_NUMERAIRE_NATIVE) {
            IERC20(numeraire).approve(address(swapRouter), uint256(mintAmount));
        }

        BalanceDelta delta = swapRouter.swap{ value: IS_NUMERAIRE_NATIVE ? mintAmount : 0 }(
            poolKey,
            IPoolManager.SwapParams(
                !isToken0, amount, isToken0 ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1
            ),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
        uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

        return isToken0 ? (delta0, delta1) : (delta1, delta0);
    }

    // default function to be overloaded by `from`
    function buyWithNumeraire(PoolKey memory poolKey, bool isToken0, int256 amount) public returns (uint256, uint256) {
        return buyWithNumeraire(address(this), poolKey, isToken0, amount);
    }

    /// @dev Sells a given amount of asset tokens for numeraire
    function sellWithAsset(
        address assetAddress,
        address from,
        PoolKey memory poolKey,
        bool isToken0,
        int256 amount
    ) public returns (uint256, uint256) {
        // Negative means exactIn, positive means exactOut.
        uint256 approveAmount = amount < 0 ? uint256(-amount) : uint256(amount) * 2; // * 2 to skip computing the amount needed for exactOut
        vm.startPrank(from);
        IERC20(assetAddress).approve(address(swapRouter), uint256(approveAmount));

        BalanceDelta delta = swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams(isToken0, amount, isToken0 ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();

        uint256 delta0 = uint256(int256(delta.amount0() < 0 ? -delta.amount0() : delta.amount0()));
        uint256 delta1 = uint256(int256(delta.amount1() < 0 ? -delta.amount1() : delta.amount1()));

        return isToken0 ? (delta0, delta1) : (delta1, delta0);
    }

    // default function to be overloaded by `assetAddress` and `from`
    function sellWithAsset(PoolKey memory poolKey, bool isToken0, int256 amount) public returns (uint256, uint256) {
        return sellWithAsset(asset, address(this), poolKey, isToken0, amount);
    }

    function _getBalances(PoolKey memory key) internal view returns (uint256 assetBalance, uint256 numeraireBalance) {
        assetBalance = IS_ASSET_TOKEN0 ? key.currency0.balanceOf(address(this)) : key.currency1.balanceOf(address(this));
        numeraireBalance =
            IS_ASSET_TOKEN0 ? key.currency1.balanceOf(address(this)) : key.currency0.balanceOf(address(this));
    }

    function _getNumeraireBalance(address user) internal view returns (uint256 balance) {
        balance = IS_NUMERAIRE_NATIVE ? user.balance : IERC20(numeraire).balanceOf(user);
    }
}

