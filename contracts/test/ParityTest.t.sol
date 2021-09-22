// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

// TODO: fix erc20_mint, since StateManipulations and TestUtils both have hevm

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";
import { LoanUser }                      from "../../modules/loan/contracts/test/accounts/LoanUser.sol";

// TODO: init all existing contracts as globals in setUp, wrapped with IContractLike from interfaces directory

// Governor                0xd6d4Bcde6c816F17889f1Dd3000aF0261B03a196
// GlobalAdmin             0x93CC3E39C91cf93fd57acA416ed6fE66e8bdD573
// SecurityAdmin           0x6b1A78C1943b03086F7Ee53360f9b0672bD60818
// USDC                    0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
// WBTC                    0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
// WETH9                   0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
// MapleToken              0x33349B282065b0284d756F0577FB39c158F935e6
// UniswapV2Router02       0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D
// BFactory                0x9424B1412450D0f8Fc2255FAf6046b98213B76Bd
// ChainLinkAggregatorWBTC 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c
// BPool                   0xc1b10e536CD611aCFf7a7c32A9E29cE6A02Ef6ef
// MapleGlobals            0xC234c62c8C09687DFf0d9047e40042cd166F3600
// Util                    0x95f9676A34aF2675B63948dDba8F8c798741A52a
// PoolLib                 0x2c1C30fb8cC313Ef3cfd2E2bBf2da88AdD902C30
// LoanLib                 0x51A189ccD2eB5e1168DdcA7e59F7c8f39AA52232
// MapleTreasury           0xa9466EaBd096449d650D5AEB0dD3dA6F52FD0B19
// RepaymentCalc           0x7d622bB6Ed13a599ec96366Fa95f2452c64ce602
// LateFeeCalc             0x8dC5aa328142aa8a008c25F66a77eaA8E4B46f3c
// PremiumCalc             0xe88Ab4Cf1Ec06840d16feD69c964aD9DAFf5c6c2
// PoolFactory             0x2Cd79F7f8b38B9c0D80EA6B230441841A31537eC
// StakeLockerFactory      0x53a597A4730Eb02095dD798B203Dcc306348B8d6
// LiquidityLockerFactory  0x966528BB1C44f96b3AA8Fbf411ee896116b068C9
// DebtLockerFactory       0x2a7705594899Db6c3924A872676E54f041d1f9D8
// LoanFactory             0x908cC851Bc757248514E060aD8Bd0a03908308ee
// CollateralLockerFactory 0xEE3e59D381968f4F9C92460D9d5Cfcf5d3A67987
// FundingLockerFactory    0x0eB96A53EC793a244876b018073f33B23000F25b
// MplRewardsFactory       0x0155729EbCd47Cb1fBa02bF5a8DA20FaF3860535
// PriceOracleAAVE         0xCc903496EDEE42F1A298C63905c19a42AF708b15
// PriceOracleLINK         0x5ad18e4ce9c88c3c266a1befe924cd6eaf812f24
// PriceOracleUSDC         0x5DC5E14be1280E747cD036c089C96744EBF064E7
// PriceOracleWBTC         0xF808ec05c1760DE4794813d08d2Bf1E16e7ECD0B

contract ParityTest is TestUtils, StateManipulations {

    function setUp() external {

    }

}
