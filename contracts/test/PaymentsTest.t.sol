// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";

import { MapleProxyFactory } from "../../modules/debt-locker/modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";  // TODO: Import MPF

import { DebtLocker }            from "../../modules/debt-locker/contracts/DebtLocker.sol";
import { DebtLockerFactory }     from "../../modules/debt-locker/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker/contracts/DebtLockerInitializer.sol";

import { Liquidator }        from "../../modules/liquidations/contracts/Liquidator.sol";
import { Rebalancer }        from "../../modules/liquidations/contracts/test/Liquidator.t.sol";
import { SushiswapStrategy } from "../../modules/liquidations/contracts/SushiswapStrategy.sol";
import { UniswapV2Strategy } from "../../modules/liquidations/contracts/UniswapV2Strategy.sol";

import { IMapleLoan } from "../../modules/loan/contracts/interfaces/IMapleLoan.sol";

import { MapleLoan }            from "../../modules/loan/contracts/MapleLoan.sol";
import { MapleLoanFactory }     from "../../modules/loan/contracts/MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../../modules/loan/contracts/MapleLoanInitializer.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Keeper }   from "./accounts/Keeper.sol";
import { Lender }   from "./accounts/Lender.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

import {
    ILoanV1Like,
    IMapleGlobalsLike,
    IPoolLibLike,
    IPoolLike,
    IStakeLockerLike
} from "./interfaces/Interfaces.sol";


contract PaymentsTest is AddressRegistry, StateManipulations, TestUtils {

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
    }

    function test_latePayments() external {

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

        // 5 BTC @ ~$58k = $290k = 29% collateralized, interest only
        uint256[3] memory requests = [uint256(5 * BTC), uint256(1_000_000 * USD), uint256(1_000_000 * USD)];  

        uint256[4] memory fees = [uint256(0), uint256(0), uint256(0), uint256(0.05e18)];  // TODO: Set up fees for parity

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, parameters, requests, fees);

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments));

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
        // assertEq(usdc.balanceOf(ORTHOGONAL_SL),   usdc_stakeLockerBal     += 0);
        // assertEq(usdc.balanceOf(ORTHOGONAL_PD),   usdc_poolDelegateBal    += establishmentFee);  // Investor estab fee
        // assertEq(usdc.balanceOf(MAPLE_TREASURY),  usdc_treasuryBal        += establishmentFee);  // Treasury estab fee

        // assertEq(usdc.balanceOf(address(loanV2)), fundAmount - establishmentFee * 2);  // Remaining funds
        
        /*********************/
        /*** Drawdown Loan ***/
        /*********************/
        uint256 drawableFunds = fundAmount - establishmentFee * 2;

        // erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

        // assertEq(loanV2.drawableFunds(),            drawableFunds);
        // assertEq(usdc.balanceOf(address(loanV2)),   drawableFunds);
        // assertEq(usdc.balanceOf(address(borrower)), 0);
        // assertEq(wbtc.balanceOf(address(borrower)), 5 * BTC);
        // assertEq(wbtc.balanceOf(address(loanV2)),   0);
        // assertEq(loanV2.collateral(),               0);

        // borrower.erc20_transfer(WBTC, address(loanV2), 5 * BTC);
        // borrower.loan_postCollateral(address(loanV2), 0);
        // borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));

        // assertEq(loanV2.drawableFunds(),            0);
        // assertEq(usdc.balanceOf(address(loanV2)),   0);
        // assertEq(usdc.balanceOf(address(borrower)), drawableFunds);
        // assertEq(wbtc.balanceOf(address(borrower)), 0);
        // assertEq(wbtc.balanceOf(address(loanV2)),   5 * BTC);
        // assertEq(loanV2.collateral(),               5 * BTC);
        
        // /********************************/
        // /*** Make Payment 1 (On time) ***/
        // /********************************/

        // hevm.warp(loanV2.nextPaymentDueDate());

        // // Check details for upcoming payment #1
        // ( uint256 principalPortion, uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();

        // assertEq(principalPortion, 0);
        // assertEq(interestPortion,  9863_013698);

        // // Make first payment
        // erc20_mint(USDC, 9, address(borrower), interestPortion);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     0);
        // assertEq(loanV2.nextPaymentDueDate(), start + 30 days);
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  3);

        // assertEq(usdc.balanceOf(address(loanV2)), 0);

        // borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        // borrower.loan_makePayment(address(loanV2), 0);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     interestPortion);
        // assertEq(loanV2.nextPaymentDueDate(), start + 60 days);
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  2);

        // assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/
        // uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        // assertEq(usdc.balanceOf(address(loanV2)), 0);

        // assertEq(details[0], interestPortion);
        // assertEq(details[1], interestPortion);
        // assertEq(details[2], 0);
        // assertEq(details[3], 0);
        // assertEq(details[4], 0);
        // assertEq(details[5], 0);
        // assertEq(details[6], 0);

        // uint256 ongoingFee = interestPortion * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        // assertEq(pool.principalOut(),            pool_principalOut       += 0);
        // assertEq(pool.interestSum(),             pool_interestSum        += interestPortion - 2 * ongoingFee);  // 80% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal += interestPortion - 2 * ongoingFee);  // 80% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal     += ongoingFee);                        // 10% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal    += ongoingFee);                        // 10% of interest
        // assertEq(usdc.balanceOf(MAPLE_TREASURY), usdc_treasuryBal        += 0);

        /*****************************/
        /*** Make Payment 2 (Late) ***/
        /*****************************/

        // hevm.warp(loanV2.nextPaymentDueDate() + 1 days);  // 1 day late

        // // Check details for upcoming payment #2
        // ( principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        // uint256 lateInterest = 1972_602739;
        // uint256 lateFee = 50_000 * USD; // Rate for late payment over the principal

        // emit log_named_uint("late fee", lateFee);
        // emit log_named_uint("interestPortion", interestPortion);
        // emit log_named_uint("sub", interestPortion -9863_013698-lateFee);


        // assertEq(principalPortion, 0);
        // assertEq(interestPortion,  9863_013698 + lateFee + lateInterest);  // Interest + 1972_602739

        // // Make second payment
        // erc20_mint(USDC, 9, address(borrower), interestPortion);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     0);                // Claim has been made
        // assertEq(loanV2.nextPaymentDueDate(), start + 60 days);  // Payment 2 due date
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  2);

        // assertEq(usdc.balanceOf(address(loanV2)), 0);

        // borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        // borrower.loan_makePayment(address(loanV2), 0);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     interestPortion);
        // assertEq(loanV2.nextPaymentDueDate(), start + 90 days);  // Payment 3 due date
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  1);

        // assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        // /******************************/
        // /*** Make Payment 3 (Final) ***/
        // /******************************/

        // hevm.warp(loanV2.nextPaymentDueDate());

        // // Check details for upcoming payment #3
        // ( principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        // assertEq(principalPortion, 1_000_000 * USD);
        // assertEq(interestPortion,  9863_013698);

        // // Make second payment
        // erc20_mint(USDC, 9, address(borrower), 1_009_863_013698);  // Principal + interest

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     interestPortion);
        // assertEq(loanV2.nextPaymentDueDate(), start + 90 days);  // Payment 3 due date
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  1);

        // assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        // borrower.erc20_transfer(USDC, address(loanV2), 1_009_863_013698);
        // borrower.loan_makePayment(address(loanV2), 0);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     1_000_000 * USD + interestPortion * 2);
        // assertEq(loanV2.nextPaymentDueDate(), start + 120 days); 
        // assertEq(loanV2.principal(),          0);
        // assertEq(loanV2.paymentsRemaining(),  0);

        // assertEq(usdc.balanceOf(address(loanV2)), 1_000_000 * USD + interestPortion * 2);

        /**************************************************/
        /*** Claim Funds as Pool Delegate (Two Payments ***/
        /**************************************************/
        
        // details = pool.claim(address(loanV2), address(debtLockerFactory));

        // assertEq(usdc.balanceOf(address(loanV2)), 0);

        // uint256 totalInterest = interestPortion * 2;

        // assertEq(details[0], principalPortion + totalInterest);
        // assertEq(details[1], totalInterest);
        // assertEq(details[2], principalPortion);
        // assertEq(details[3], 0);
        // assertEq(details[4], 0);
        // assertEq(details[5], 0);
        // assertEq(details[6], 0);

        // ongoingFee = totalInterest * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        // assertEq(pool.principalOut(),            pool_principalOut       -= principalPortion);
        // assertEq(pool.interestSum(),             pool_interestSum        += totalInterest - (2 * ongoingFee));                     // 80% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal += principalPortion + totalInterest - (2 * ongoingFee));  // 80% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal     += ongoingFee);                                           // 10% of interest
        // assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal    += ongoingFee);                                           // 10% of interest
        // assertEq(usdc.balanceOf(MAPLE_TREASURY), usdc_treasuryBal        += 0);
    }


}