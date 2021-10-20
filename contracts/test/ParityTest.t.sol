// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";

import { DebtLockerFactory } from "../../modules/debt-locker/contracts/DebtLockerFactory.sol";

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

    uint256 start;

    Borrower borrower;

    DebtLockerFactory debtLockerFactory;

    MapleLoan            loanImplementation;
    MapleLoanFactory     loanFactory;
    MapleLoanInitializer loanInitializer;

    ILoanV1Like loanV1;
    IMapleLoan  loanV2;

    IMapleGlobalsLike globals = IMapleGlobalsLike(MAPLE_GLOBALS);
    IPoolLike         pool    = IPoolLike(ORTHOGONAL_POOL);        // Using deployed Orthogonal Pool

    IERC20 usdc = IERC20(USDC);
    IERC20 wbtc = IERC20(WBTC);

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

        // TODO: Make upgradeable

        debtLockerFactory = new DebtLockerFactory();

        globals.setValidSubFactory(POOL_FACTORY, address(debtLockerFactory), true);  // Whitelist new LoanFactory

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

        loanV2 = IMapleLoan(borrower.mapleLoanFactory_createLoan(address(loanFactory), arguments));
    }

    function test_endToEndLoan() external {
        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 fundAmount       = 1_000_000 * USD;
        uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps

        assertEq(pool.principalOut()            , 98_300_000_000000);
        assertEq(usdc.balanceOf(ORTHOGONAL_LL)  ,  3_508_684_976740);
        assertEq(usdc.balanceOf(ORTHOGONAL_PD)  ,     90_906_643828);
        assertEq(usdc.balanceOf(MAPLE_TREASURY) ,    596_625_000000);
        assertEq(usdc.balanceOf(address(loanV2)),                 0);
        
        pool.fundLoan(address(loanV2), address(debtLockerFactory), fundAmount);

        assertEq(pool.principalOut()            , 98_300_000_000000 + fundAmount);
        assertEq(usdc.balanceOf(ORTHOGONAL_LL)  ,  3_508_684_976740 - fundAmount);
        assertEq(usdc.balanceOf(ORTHOGONAL_PD)  ,     90_906_643828 + establishmentFee);                   // Investor estab fee
        assertEq(usdc.balanceOf(MAPLE_TREASURY) ,    596_625_000000 + establishmentFee);                   // Treasury estab fee
        assertEq(usdc.balanceOf(address(loanV2)),                 0 + fundAmount - establishmentFee * 2);  // Remaining funds

        /*********************/
        /*** Drawdown Loan ***/
        /*********************/

        uint256 drawableFunds = fundAmount - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 250 * BTC);

        assertEq(loanV2.drawableFunds(),            drawableFunds);
        assertEq(usdc.balanceOf(address(loanV2)),   drawableFunds);
        assertEq(usdc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(borrower)), 250 * BTC);
        assertEq(wbtc.balanceOf(address(loanV2)),   0);
        assertEq(loanV2.collateral(),               0);

        borrower.erc20_transfer(WBTC, address(loanV2), 250 * BTC);
        borrower.loan_postCollateral(address(loanV2));
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));

        assertEq(loanV2.drawableFunds(),            0);
        assertEq(usdc.balanceOf(address(loanV2)),   0);
        assertEq(usdc.balanceOf(address(borrower)), drawableFunds);
        assertEq(wbtc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(loanV2)),   250 * BTC);
        assertEq(loanV2.collateral(),               250 * BTC);

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
        assertEq(loanV2.nextPaymentDueDate(), block.timestamp);  // Warped to due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  3);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2));

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     9863_013698);
        assertEq(loanV2.nextPaymentDueDate(), block.timestamp + loanV2.paymentInterval());
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  2);

        /*****************************/
        /*** Make Payment 2 (Late) ***/
        /*****************************/

        hevm.warp(loanV2.nextPaymentDueDate() + 1 days);  // 1 day late

        // Check details for upcoming payment #2
        ( principalPortion, interestPortion, feesPortion ) = loanV2.getNextPaymentsBreakDown(1);

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  11_835_616437);  // Interest + 1972_602739
        assertEq(feesPortion,      0);

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     9863_013698);
        assertEq(loanV2.nextPaymentDueDate(), block.timestamp - 1 days);  // 1 day late
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  2);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2));

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     20_056_692599);
        assertEq(loanV2.nextPaymentDueDate(), block.timestamp + loanV2.paymentInterval() - 1 days);   // 29 days from current timestamp
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  1);

        // /******************************/
        // /*** Make Payment 3 (Final) ***/
        // /******************************/

        // hevm.warp(loanV2.nextPaymentDueDate());  // 1 day late

        // // Check details for upcoming payment #2
        // ( principalPortion, interestPortion, feesPortion ) = loanV2.getNextPaymentsBreakDown(1);

        // assertEq(principalPortion, 1_000_000 * USD);
        // assertEq(interestPortion,  9863_013698);
        // assertEq(feesPortion,      0);

        // // Make second payment
        // erc20_mint(USDC, 9, address(borrower), 1_009_863 * USD);

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     20_056_692599);
        // assertEq(loanV2.nextPaymentDueDate(), block.timestamp);  // On time
        // assertEq(loanV2.principal(),          1_000_000 * USD);
        // assertEq(loanV2.paymentsRemaining(),  1);

        // borrower.erc20_transfer(USDC, address(loanV2), 1_009_863 * USD);
        // borrower.loan_makePayment(address(loanV2));

        // assertEq(loanV2.drawableFunds(),      0);
        // assertEq(loanV2.claimableFunds(),     1_029_919_692599);
        // assertEq(loanV2.nextPaymentDueDate(), block.timestamp + loanV2.paymentInterval());
        // assertEq(loanV2.principal(),          0);
        // assertEq(loanV2.paymentsRemaining(),  0);
    }

}
