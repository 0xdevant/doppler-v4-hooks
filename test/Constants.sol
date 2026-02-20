// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

abstract contract Constants {
    address public constant BASE_WETH = 0x4200000000000000000000000000000000000006;

    address public constant BASE_POOL_MANAGER = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    address public constant BASE_AIRLOCK = 0x660eAaEdEBc968f8f3694354FA8EC0b4c5Ba8D12;
    address public constant BASE_TOKEN_FACTORY = 0x80A27Feee1A22b9c68185ea64E7c2652286980B5;
    address public constant BASE_GOVERNANCE_FACTORY = 0xb4deE32EB70A5E55f3D2d861F49Fb3D79f7a14d9;
    address public constant BASE_MIGRATOR_MULTICURVE = 0x6ddfED58D238Ca3195E49d8ac3d4cEa6386E5C33;
    address public constant BASE_V4_MULTICURVE_INITIALIZER = 0x65dE470Da664A5be139A5D812bE5FDa0d76CC951;
    address public constant BASE_MULTICURVE_HOOKS = 0x892D3C2B4ABEAAF67d52A7B29783E2161B7CaD40;
    address public constant BASE_DOPPLER_BENEFICIARY = 0x21E2ce70511e4FE542a97708e89520471DAa7A66;
    address public constant BASE_DOPPLER_LENS_QUOTER = 0x43d0D97EC9241A8F05A264f94B82A1d2E600f2B3;
    address public constant BASE_UNIVERSAL_ROUTER = 0x6fF5693b99212Da76ad316178A184AB56D299b43;
    address public constant BASE_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address public constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address public constant BASE_SEPOLIA_AIRLOCK = 0x3411306Ce66c9469BFF1535BA955503c4Bde1C6e;
    address public constant BASE_SEPOLIA_V4_MULTICURVE_INITIALIZER = 0x1718405E58c61425cDc0083262bC9f72198F5232;

    // test configs
    string constant TOKEN_NAME = "Test Token";
    string constant TOKEN_SYMBOL = "TEST";
    string constant TOKEN_URI = "TOKEN_URI";

    uint256 constant INITIAL_SUPPLY = 1e23;

    uint256 constant BUY_NUMERAIRE_AMOUNT = 0.5 ether; // 0.5 numeraire
    uint256 constant BUY_ASSET_AMOUNT = 3 ether; // 3 token
    uint256 constant SELL_ASSET_AMOUNT = 0.25 ether; // 0.25 token
}
