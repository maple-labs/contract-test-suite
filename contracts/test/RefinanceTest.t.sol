// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";

import { MapleProxyFactory } from "../../modules/debt-locker/modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";  // TODO: Import MPF

import { DebtLocker }            from "../../modules/debt-locker/contracts/DebtLocker.sol";
import { DebtLockerFactory }     from "../../modules/debt-locker/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker/contracts/DebtLockerInitializer.sol";

import { IMapleLoan } from "../../modules/loan/contracts/interfaces/IMapleLoan.sol";

import { MapleLoan }            from "../../modules/loan/contracts/MapleLoan.sol";
import { MapleLoanFactory }     from "../../modules/loan/contracts/MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../../modules/loan/contracts/MapleLoanInitializer.sol";
import { Refinancer }           from "../../modules/loan/contracts/Refinancer.sol";

import { Borrower } from "./accounts/Borrower.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

import { IMapleGlobalsLike, IPoolLike } from "./interfaces/Interfaces.sol";

contract RefinanceTest is AddressRegistry, StateManipulations, TestUtils {

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

    Refinancer refinancer;

    function setUp() external {

        /*******************************/
        /*** Set up actors and state ***/
        /*******************************/

        start = block.timestamp;

        // Set existing Orthogonal PD as Governor
        hevm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

        borrower = new Borrower();

        /*************************************************************/
        /*** Deploy and set up new LoanFactory with implementation ***/
        /*************************************************************/

        // Deploy new LoanFactory, implementation, and initializer
        loanFactory        = new MapleLoanFactory(MAPLE_GLOBALS);
        loanImplementation = new MapleLoan();
        loanInitializer    = new MapleLoanInitializer();

        // // Register the new implementations and set default version
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

        refinancer = new Refinancer();
    }

    function test_refinance_multipleActions() external {

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

        uint256[4] memory rates = [uint256(0.12e18), uint256(0), uint256(0.05e18), uint256(0.6e18)]; 

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments));

        {
            /*****************/
            /*** Fund Loan ***/
            /*****************/

            uint256 fundAmount       = 1_000_000 * USD;
            uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps
            
            assertEq(usdc.balanceOf(address(loanV2)), 0);
            
            pool.fundLoan(address(loanV2), address(debtLockerFactory), fundAmount);
            
            /*********************/
            /*** Drawdown Loan ***/
            /*********************/

            uint256 drawableFunds = fundAmount - establishmentFee * 2;

            erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

            borrower.erc20_transfer(WBTC, address(loanV2), 5 * BTC);
            borrower.loan_postCollateral(address(loanV2), 0);
            borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));
        }
        
        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV2), address(debtLockerFactory));

        /*****************/
        /*** Refinance ***/
        /*****************/

        // Refinance parameters

        uint256[3] memory refinanceTermDetails = [
            uint256(15 days),  // 15 day grace period
            uint256(45 days),  // 45 day payment interval
            uint256(3)
        ];

        // 2 BTC @ ~$58k = $116k = 11.6% collateralized, partially amortized
        uint256[3] memory refinanceRequests = [uint256(2 * BTC), uint256(2_000_000 * USD), uint256(1_000_000 * USD)];  

        uint256[4] memory refinanceRates = [uint256(0.10e18), uint256(0), uint256(0.04e18), uint256(0.4e18)];

        uint256 principalIncrease = refinanceRequests[1] - requests[1];

        bytes[] memory data = new bytes[](9);
        data[0] = abi.encodeWithSelector(Refinancer.setGracePeriod.selector,       refinanceTermDetails[0]);
        data[1] = abi.encodeWithSelector(Refinancer.setPaymentInterval.selector,   refinanceTermDetails[1]);
        data[2] = abi.encodeWithSelector(Refinancer.setPaymentsRemaining.selector, refinanceTermDetails[2]);

        data[3] = abi.encodeWithSelector(Refinancer.setCollateralRequired.selector, refinanceRequests[0]);
        data[4] = abi.encodeWithSelector(Refinancer.increasePrincipal.selector,     principalIncrease);
        data[5] = abi.encodeWithSelector(Refinancer.setEndingPrincipal.selector,    refinanceRequests[2]);

        data[6] = abi.encodeWithSelector(Refinancer.setInterestRate.selector,        refinanceRates[0]);
        data[7] = abi.encodeWithSelector(Refinancer.setLateFeeRate.selector,         refinanceRates[2]);
        data[8] = abi.encodeWithSelector(Refinancer.setLateInterestPremium.selector, refinanceRates[3]);

        borrower.loan_proposeNewTerms(address(loanV2), address(refinancer), data);

        // Pool Delegate(address this) accepts new terms on Debt Locker
        DebtLocker debtLocker = DebtLocker(loanV2.lender());

        // Fails if there're no extra funds from pool
        try debtLocker.acceptNewTerms(address(refinancer), data, principalIncrease) { assertTrue(false, "shouldn't succeed"); } catch { }

        // Pool Delegate funds loan again for increasing amount
        pool.fundLoan(address(loanV2), address(debtLockerFactory), principalIncrease);

        debtLocker.acceptNewTerms(address(refinancer), data, principalIncrease);
        
        assertEq(loanV2.gracePeriod(),       refinanceTermDetails[0]);
        assertEq(loanV2.paymentInterval(),   refinanceTermDetails[1]);
        assertEq(loanV2.paymentsRemaining(), refinanceTermDetails[2]);

        assertEq(loanV2.principalRequested(), requests[1] + principalIncrease);
        assertEq(loanV2.principal(),          requests[1] + principalIncrease);
        assertEq(loanV2.collateralRequired(), refinanceRequests[0]);

        assertEq(loanV2.interestRate(),        refinanceRates[0]);
        assertEq(loanV2.lateFeeRate(),         refinanceRates[2]);
        assertEq(loanV2.lateInterestPremium(), refinanceRates[3]);

        /****************************/
        /*** Make Another payment ***/
        /****************************/

        // Drawdown extra amount
        borrower.loan_drawdownFunds(address(loanV2), principalIncrease, address(borrower));

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        (  principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        // Principal is non-zero since the loan is now partially amortized
        assertEq(principalPortion, 329_257_314375);
        assertEq(interestPortion,   24_657_534246);

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion + principalPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     interestPortion + principalPortion);
        assertEq(loanV2.nextPaymentDueDate(), block.timestamp + 45 days);
        assertEq(loanV2.principal(),          2_000_000 * USD - principalPortion);
        assertEq(loanV2.paymentsRemaining(),  2);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], principalPortion + interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

    }

}
