// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

contract AddressRegistry {

    /**************************/
    /*** External Contracts ***/
    /**************************/

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /***********************************/
    /*** Deployed Protocol Contracts ***/
    /***********************************/

    address constant GOVERNOR            = 0xd6d4Bcde6c816F17889f1Dd3000aF0261B03a196;
    address constant MPL                 = 0x33349B282065b0284d756F0577FB39c158F935e6;
    address constant BALANCER_POOL       = 0xc1b10e536CD611aCFf7a7c32A9E29cE6A02Ef6ef;
    address constant MAPLE_GLOBALS       = 0xC234c62c8C09687DFf0d9047e40042cd166F3600;
    address constant MAPLE_TREASURY      = 0xa9466EaBd096449d650D5AEB0dD3dA6F52FD0B19;
    address constant POOL_FACTORY        = 0x2Cd79F7f8b38B9c0D80EA6B230441841A31537eC;
    address constant LOAN_FACTORY        = 0x908cC851Bc757248514E060aD8Bd0a03908308ee;
    address constant MPL_REWARDS_FACTORY = 0x0155729EbCd47Cb1fBa02bF5a8DA20FaF3860535;
    address constant CL_FACTORY          = 0xEE3e59D381968f4F9C92460D9d5Cfcf5d3A67987;
    address constant DL_FACTORY          = 0x2a7705594899Db6c3924A872676E54f041d1f9D8;
    address constant FL_FACTORY          = 0x0eB96A53EC793a244876b018073f33B23000F25b;
    address constant SL_FACTORY          = 0x53a597A4730Eb02095dD798B203Dcc306348B8d6;
    address constant LL_FACTORY          = 0x966528BB1C44f96b3AA8Fbf411ee896116b068C9;
    address constant REPAYMENT_CALC      = 0x7d622bB6Ed13a599ec96366Fa95f2452c64ce602;
    address constant LATEFEE_CALC        = 0x8dC5aa328142aa8a008c25F66a77eaA8E4B46f3c;
    address constant PREMIUM_CALC        = 0xe88Ab4Cf1Ec06840d16feD69c964aD9DAFf5c6c2;

    /*******************************/
    /*** Deployed Pool Contracts ***/
    /*******************************/
    
    address constant ORTHOGONAL_PD       = 0xA6cCb9483E3E7a737E3a4F5B72a1Ce51838ba122;
    address constant ORTHOGONAL_POOL     = 0xFeBd6F15Df3B73DC4307B1d7E65D46413e710C27;
    address constant ORTHOGONAL_POOL_LIB = 0x2c1C30fb8cC313Ef3cfd2E2bBf2da88AdD902C30;
    address constant ORTHOGONAL_SL       = 0x12B2BbBfAB2CE6789DF5659E9AC27A4A91C96C5C;
    address constant ORTHOGONAL_LL       = 0xB5321058E209E0F6C1216A7c7922B6962681DD77;
    address constant ORTHOGONAL_REWARDS  = 0x7869D7a3B074b5fa484dc04798E254c9C06A5e90;

}
