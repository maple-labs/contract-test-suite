// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";

import { DebtLocker }            from "../../modules/debt-locker/contracts/DebtLocker.sol";
import { DebtLockerFactory }     from "../../modules/debt-locker/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker/contracts/DebtLockerInitializer.sol";

import { IMapleLoan } from "../../modules/loan/contracts/interfaces/IMapleLoan.sol";

import { MapleLoan }            from "../../modules/loan/contracts/MapleLoan.sol";
import { MapleLoanFactory }     from "../../modules/loan/contracts/MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../../modules/loan/contracts/MapleLoanInitializer.sol";

import { IMapleGlobalsLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { Borrower }       from "./accounts/Borrower.sol";
import { GenericAccount } from "./accounts/GenericAccount.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

contract UpgradeTest is AddressRegistry, StateManipulations, TestUtils {

    uint256 constant WAD = 10 ** 18;  // ETH  precision
    uint256 constant BTC = 10 ** 8;   // WBTC precision
    uint256 constant USD = 10 ** 6;   // USDC precision

    // Mainnet State Constants 
    // Block 13499527 - Wednesday, October 27, 2021 12:58:18 PM UTC
    // Using Orthogonal Pool for testing
    uint256 constant PRINCIPAL_OUT     = 132_000_000_000000;
    uint256 constant INTEREST_SUM      =     868_794_717158;
    uint256 constant LL_USDC_BAL       =   6_516_420_406721;
    uint256 constant SL_USDC_BAL       =     179_170_813216;
    uint256 constant PD_USDC_BAL       =     122_108_154489;
    uint256 constant TREASURY_USDC_BAL =     769_625_000000;

    uint256 start;

    // Mainnet State Variables
    uint256 bpt_stakeLockerBal;
    uint256 pool_principalOut;
    uint256 pool_interestSum;
    uint256 usdc_liquidityLockerBal;
    uint256 usdc_stakeLockerBal;
    uint256 usdc_poolDelegateBal;
    uint256 usdc_treasuryBal;

    Borrower borrower;
    Borrower notBorrower;

    DebtLocker            debtLockerImplementation;
    DebtLockerFactory     debtLockerFactory;
    DebtLockerInitializer debtLockerInitializer;

    IMapleLoan loanV2;

    IMapleGlobalsLike globals = IMapleGlobalsLike(MAPLE_GLOBALS);
    IPoolLike         pool    = IPoolLike(ORTHOGONAL_POOL);        // Using deployed Orthogonal Pool

    IERC20 bpt  = IERC20(BALANCER_POOL);
    IERC20 usdc = IERC20(USDC);
    IERC20 wbtc = IERC20(WBTC);

    MapleLoan            loanImplementation;
    MapleLoanFactory     loanFactory;
    MapleLoanInitializer loanInitializer;

    function setUp() external {

        /*******************************/
        /*** Set up actors and state ***/
        /*******************************/

        start = block.timestamp;

        // Set existing Orthogonal PD as Governor
        hevm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

        borrower    = new Borrower();
        notBorrower = new Borrower();

        /*********************************************/
        /*** Whitelist collateral and funds assets ***/
        /*********************************************/

        globals.setCollateralAsset(WBTC, true);
        globals.setLiquidityAsset(USDC, true);

        /*************************************************************/
        /*** Deploy and set up new LoanFactory with implementation ***/
        /*************************************************************/

        // Deploy new LoanFactory, implementation, and initializer
        loanFactory        = new MapleLoanFactory(MAPLE_GLOBALS);
        loanImplementation = new MapleLoan();
        loanInitializer    = new MapleLoanInitializer();

        // Register the new implementations and set default version
        loanFactory.registerImplementation(1, address(loanImplementation), address(loanInitializer));
        loanFactory.setDefaultVersion(1);

        globals.setValidLoanFactory(address(loanFactory), true);  // Whitelist new LoanFactory

        /***********************************************/
        /*** Deploy and set up new DebtLockerFactory ***/
        /***********************************************/

        // Deploy new LoanFactory, implementation, and initializer
        debtLockerFactory        = new DebtLockerFactory(MAPLE_GLOBALS);
        debtLockerImplementation = new DebtLocker();
        debtLockerInitializer    = new DebtLockerInitializer();

        // Register the new implementations and set default version
        debtLockerFactory.registerImplementation(1, address(debtLockerImplementation), address(debtLockerInitializer));
        debtLockerFactory.setDefaultVersion(1);

        globals.setValidSubFactory(POOL_FACTORY, address(debtLockerFactory), true);  // Whitelist new debtLockerFactory
        assertTrue(globals.isValidSubFactory(POOL_FACTORY, address(debtLockerFactory), 1));

        /*********************/
        /*** Deploy LoanV2 ***/
        /*********************/

        address[2] memory assets = [WBTC, USDC];

        uint256[3] memory termDetails = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3)
        ];

        // 5 BTC @ ~$58k = $290k = 29% collateralized, interest only
        uint256[3] memory requests = [uint256(5 * BTC), uint256(1_000_000 * USD), uint256(1_000_000 * USD)];  

        uint256[4] memory rates = [uint256(0.12e18), uint256(0), uint256(0), uint256(0.6e18)];

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));
    }

    function test_loanUpgrades() external {

        /********************/
        /*** Upgrade Loan ***/
        /********************/

        // Deploying and registering a new version
        address loanImplementation2 = address(new MapleLoan());
        loanFactory.registerImplementation(2, address(loanImplementation2), address(loanInitializer));
        loanFactory.enableUpgradePath(1, 2, address(0));

        assertEq(loanV2.implementation(), address(loanImplementation));
        assertEq(loanV2.factory(),        address(loanFactory));

        // Not borrower can't migrate
        try notBorrower.loan_upgrade(address(loanV2),2, new bytes(0)) { assertTrue(false, "Non-borrower could upgrade"); } catch { }

        // Nothing changes
        assertEq(loanV2.implementation(), address(loanImplementation));
        assertEq(loanV2.factory(),        address(loanFactory));

        borrower.loan_upgrade(address(loanV2), 2, new bytes(0));

        assertEq(loanV2.implementation(), address(loanImplementation2));
        assertEq(loanV2.factory(),        address(loanFactory));
    }

    function test_debtLockerUpgrades() external {

        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 fundAmount       = 1_000_000 * USD;
        uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps

        assertEq(pool_principalOut       = pool.principalOut(),            PRINCIPAL_OUT);
        assertEq(pool_interestSum        = pool.interestSum(),             INTEREST_SUM);
        assertEq(usdc_liquidityLockerBal = usdc.balanceOf(ORTHOGONAL_LL),  LL_USDC_BAL);
        assertEq(usdc_stakeLockerBal     = usdc.balanceOf(ORTHOGONAL_SL),  SL_USDC_BAL);
        assertEq(usdc_poolDelegateBal    = usdc.balanceOf(ORTHOGONAL_PD),  PD_USDC_BAL);
        assertEq(usdc_treasuryBal        = usdc.balanceOf(MAPLE_TREASURY), TREASURY_USDC_BAL);
        
        assertEq(usdc.balanceOf(address(loanV2)), 0);
        
        pool.fundLoan(address(loanV2), address(debtLockerFactory), fundAmount);

        assertEq(pool.principalOut(),             pool_principalOut       += fundAmount);
        assertEq(pool.interestSum(),              pool_interestSum        += 0);
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),   usdc_liquidityLockerBal -= fundAmount);
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),   usdc_stakeLockerBal     += 0);
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),   usdc_poolDelegateBal    += establishmentFee);  // Investor estab fee
        assertEq(usdc.balanceOf(MAPLE_TREASURY),  usdc_treasuryBal        += establishmentFee);  // Treasury estab fee

        assertEq(usdc.balanceOf(address(loanV2)), fundAmount - establishmentFee * 2);  // Remaining funds

        /***************************/
        /*** Upgrade Debt Locker ***/
        /***************************/

        // Deploying and registering a new version
        address debtLockerV2 = address(new DebtLocker());
        debtLockerFactory.registerImplementation(2, address(debtLockerV2), address(debtLockerInitializer));
        debtLockerFactory.enableUpgradePath(1, 2, address(0));

        DebtLocker debtLocker = DebtLocker(loanV2.lender());

        assertEq(debtLocker.implementation(), address(debtLockerImplementation));
        assertEq(debtLocker.factory(),        address(debtLockerFactory));

        // Not Governor can't update
        GenericAccount account = new GenericAccount();

        try account.call(address(debtLocker), abi.encodeWithSelector(DebtLocker.upgrade.selector, 2, new bytes(0))) { 
            assertTrue(false, "Generic account could upgrade");
        } catch { }

        assertEq(debtLocker.implementation(), address(debtLockerImplementation));
        assertEq(debtLocker.factory(),        address(debtLockerFactory));
        
        // address(this) is PoolDelegate
        debtLocker.upgrade(2, new bytes(0));

        assertEq(debtLocker.implementation(), address(debtLockerV2));
        assertEq(debtLocker.factory(),        address(debtLockerFactory));
    }

}
