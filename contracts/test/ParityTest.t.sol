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

import {
    IPoolLike,
    IMapleGlobalsLike,
    ILoanV1Like
} from "./interfaces/Interfaces.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Lender }   from "./accounts/Lender.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

contract ParityTest is AddressRegistry, StateManipulations, TestUtils {

    uint256 constant WAD = 10 ** 18;  // ETH  precision
    uint256 constant BTC = 10 ** 8;   // WBTC precision
    uint256 constant USD = 10 ** 6;   // USDC precision

    // Mainnet State Constants (Block 13276702)
    // Using Orthogonal Pool for testing
    uint256 constant PRINCIPAL_OUT     = 98_300_000_000000;
    uint256 constant INTEREST_SUM      =    671_730_990939;
    uint256 constant LL_USDC_BAL       =  3_508_684_976740;
    uint256 constant SL_USDC_BAL       =    101_570_331311;
    uint256 constant PD_USDC_BAL       =     90_906_643828;
    uint256 constant TREASURY_USDC_BAL =    596_625_000000;

    uint256 start;

    // Mainnet State Variables
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

    ILoanV1Like loanV1;
    IMapleLoan  loanV2;

    IMapleGlobalsLike globals = IMapleGlobalsLike(MAPLE_GLOBALS);
    IPoolLike         pool    = IPoolLike(ORTHOGONAL_POOL);        // Using deployed Orthogonal Pool

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

        borrower = new Borrower();

        /****************************************/
        /*** Deploy LoanV1 to compare against ***/
        /****************************************/

        uint256[5] memory specs = [1_200, 90, 30, uint256(1_000_000 * USD), 10];
        address[3] memory calcs = [REPAYMENT_CALC, LATEFEE_CALC, PREMIUM_CALC];

        loanV1 = ILoanV1Like(borrower.loanFactory_createLoan(LOAN_FACTORY, USDC, WBTC, FL_FACTORY, CL_FACTORY, specs, calcs));

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

        uint256[6] memory parameters = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3),        // 3 payments (90 day term)
            uint256(0.12e18),  // 12% interest
            uint256(0.04e18),  // 4% early repayment discount
            uint256(0.6e18)    // 6% late fee premium
        ];

        // 250 BTC @ $40k = $10m = 10% collateralized, interest only
        uint256[3] memory requests = [uint256(250 * BTC), uint256(1_000_000 * USD), uint256(1_000_000 * USD)];  

        uint256[4] memory fees = [uint256(0), uint256(0), uint256(0), uint256(0)];  // TODO: Set up fees for parity

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, parameters, requests, fees);

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments));
    }

    function test_endToEndLoan() external {

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
        
        /*********************/
        /*** Drawdown Loan ***/
        /*********************/
        {
            uint256 drawableFunds = fundAmount - establishmentFee * 2;

            erc20_mint(WBTC, 0, address(borrower), 250 * BTC);

            assertEq(loanV2.drawableFunds(),            drawableFunds);
            assertEq(usdc.balanceOf(address(loanV2)),   drawableFunds);
            assertEq(usdc.balanceOf(address(borrower)), 0);
            assertEq(wbtc.balanceOf(address(borrower)), 250 * BTC);
            assertEq(wbtc.balanceOf(address(loanV2)),   0);
            assertEq(loanV2.collateral(),               0);

            borrower.erc20_transfer(WBTC, address(loanV2), 250 * BTC);
            borrower.loan_postCollateral(address(loanV2), 0);
            borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));

            assertEq(loanV2.drawableFunds(),            0);
            assertEq(usdc.balanceOf(address(loanV2)),   0);
            assertEq(usdc.balanceOf(address(borrower)), drawableFunds);
            assertEq(wbtc.balanceOf(address(borrower)), 0);
            assertEq(wbtc.balanceOf(address(loanV2)),   250 * BTC);
            assertEq(loanV2.collateral(),               250 * BTC);
        }
        
        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 feesPortion ) = loanV2.getNextPaymentsBreakDown(1);

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);
        assertEq(feesPortion,      0);

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     0);
        assertEq(loanV2.nextPaymentDueDate(), start + 30 days);
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  3);

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayments(address(loanV2), 1, 0);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     interestPortion);
        assertEq(loanV2.nextPaymentDueDate(), start + 60 days);
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  2);

        assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/
        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        uint256 ongoingFee = interestPortion * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        assertEq(pool.principalOut(),            pool_principalOut       += 0);
        assertEq(pool.interestSum(),             pool_interestSum        += interestPortion - 2 * ongoingFee);  // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal += interestPortion - 2 * ongoingFee);  // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal     += ongoingFee);                        // 10% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal    += ongoingFee);                        // 10% of interest
        assertEq(usdc.balanceOf(MAPLE_TREASURY), usdc_treasuryBal        += 0);

        /********************************/
        /*** Make Payment 2 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());  // 1 day late

        // Check details for upcoming payment #2
        ( principalPortion, interestPortion, feesPortion ) = loanV2.getNextPaymentsBreakDown(1);

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);  // Interest + 1972_602739
        assertEq(feesPortion,      0);

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     0);                // Claim has been made
        assertEq(loanV2.nextPaymentDueDate(), start + 60 days);  // Payment 2 due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  2);

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayments(address(loanV2), 1, 0);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     interestPortion);
        assertEq(loanV2.nextPaymentDueDate(), start + 90 days);  // Payment 3 due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  1);

        assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        /******************************/
        /*** Make Payment 3 (Final) ***/
        /******************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #3
        ( principalPortion, interestPortion, feesPortion ) = loanV2.getNextPaymentsBreakDown(1);

        assertEq(principalPortion, 1_000_000 * USD);
        assertEq(interestPortion,  9863_013698);
        assertEq(feesPortion,      0);

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), 1_009_863_013698);  // Principal + interest

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     interestPortion);
        assertEq(loanV2.nextPaymentDueDate(), start + 90 days);  // Payment 3 due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  1);

        assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), 1_009_863_013698);
        borrower.loan_makePayments(address(loanV2), 1, 0);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     1_000_000 * USD + interestPortion * 2);
        assertEq(loanV2.nextPaymentDueDate(), start + 120 days); 
        assertEq(loanV2.principal(),          0);
        assertEq(loanV2.paymentsRemaining(),  0);

        assertEq(usdc.balanceOf(address(loanV2)), 1_000_000 * USD + interestPortion * 2);

        /**************************************************/
        /*** Claim Funds as Pool Delegate (Two Payments ***/
        /**************************************************/
        
        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        uint256 totalInterest = interestPortion * 2;

        assertEq(details[0], principalPortion + totalInterest);
        assertEq(details[1], totalInterest);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        ongoingFee = totalInterest * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        assertEq(pool.principalOut(),            pool_principalOut       -= principalPortion);
        assertEq(pool.interestSum(),             pool_interestSum        += totalInterest - (2 * ongoingFee));                     // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal += principalPortion + totalInterest - (2 * ongoingFee));  // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal     += ongoingFee);                                           // 10% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal    += ongoingFee);                                           // 10% of interest
        assertEq(usdc.balanceOf(MAPLE_TREASURY), usdc_treasuryBal        += 0);
    }

}
