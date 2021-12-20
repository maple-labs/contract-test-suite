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

import { Borrower } from "./accounts/Borrower.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

import { IMapleGlobalsLike, IPoolLike } from "./interfaces/Interfaces.sol";



contract ClaimTest is AddressRegistry, StateManipulations, TestUtils {

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

    function createLoan(uint256 principalRequested, uint256 endingPrincipal) internal {
        address[2] memory assets = [WBTC, USDC];

        uint256[3] memory termDetails = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3)
        ];

        // 5 BTC @ ~$58k = $290k = 29% collateralized, interest only
        uint256[3] memory requests = [uint256(5 * BTC), principalRequested, endingPrincipal];  

        uint256[4] memory rates = [uint256(0.12e18), uint256(0), uint256(0.05e18), uint256(0.6e18)]; 

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));
    }

    function fundLoan() internal {
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
    }

    function drawdownLoan() internal {
        uint256 fundAmount       = 1_000_000 * USD;
        uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps
        uint256 drawableFunds = fundAmount - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

        assertEq(loanV2.drawableFunds(),            drawableFunds);
        assertEq(usdc.balanceOf(address(loanV2)),   drawableFunds);
        assertEq(usdc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(borrower)), 5 * BTC);
        assertEq(wbtc.balanceOf(address(loanV2)),   0);
        assertEq(loanV2.collateral(),               0);

        borrower.erc20_approve(WBTC, address(loanV2), 5 * BTC);
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));

        assertEq(loanV2.drawableFunds(),            0);
        assertEq(usdc.balanceOf(address(loanV2)),   0);
        assertEq(usdc.balanceOf(address(borrower)), drawableFunds);
        assertEq(wbtc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(loanV2)),   5 * BTC);
        assertEq(loanV2.collateral(),               5 * BTC);
    }

    function makeLoanPayments(uint256 payments, bool late) internal returns (uint256 totalPrincipal,uint256 totalInterest) {

        for (uint256 i = 0; i < payments; i++) {
            hevm.warp(loanV2.nextPaymentDueDate() - 1 + (late ? 3 days: 0));

            // Check details for upcoming payment #1
            ( uint256 principalPortion, uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();
            uint256 totalPayment = principalPortion + interestPortion;
            
            totalPrincipal += principalPortion;
            totalInterest  += interestPortion;

            uint256 principal         = loanV2.principal();
            uint256 paymentsRemaining = loanV2.paymentsRemaining();
            uint256 claimableFunds    = loanV2.claimableFunds();

            // Make payment
            erc20_mint(USDC, 9, address(borrower), totalPayment);
            borrower.erc20_approve(USDC, address(loanV2), totalPayment);
            borrower.loan_makePayment(address(loanV2), totalPayment);

            assertEq(loanV2.claimableFunds(),     claimableFunds + totalPayment);
            assertEq(loanV2.principal(),          principal - principalPortion);
            assertEq(loanV2.paymentsRemaining(),  paymentsRemaining - 1);
        }
    }

    function closeLoan() internal returns(uint256 principalPortion, uint256 feePortion) {
        hevm.warp(block.timestamp + 5 days);

        principalPortion = loanV2.principal();
        feePortion       = principalPortion * loanV2.earlyFeeRate() * USD / uint256(10 ** 18); // 5% on the principal 
        
        uint256 totalPayment = principalPortion + feePortion;

        // Close loan, paying a flat fee on principal
        erc20_mint(USDC, 9, address(borrower), totalPayment);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     0);
        assertEq(loanV2.nextPaymentDueDate(), start + 30 days);
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  3);

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        borrower.erc20_approve(USDC, address(loanV2), totalPayment);
        borrower.loan_closeLoan(address(loanV2), totalPayment);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     totalPayment);
        assertEq(loanV2.nextPaymentDueDate(), 0); 
        assertEq(loanV2.principal(),          0);
        assertEq(loanV2.paymentsRemaining(),  0);
    }

    function assertPoolState(uint256 principalPortion, uint256 interestPortion) internal {
        uint256 ongoingFee = interestPortion * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        assertEq(pool.principalOut(),            pool_principalOut       -= principalPortion);
        assertEq(pool.interestSum(),             pool_interestSum        += interestPortion - 2 * ongoingFee);                      // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal += principalPortion + interestPortion - 2 * ongoingFee);  // 80% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal     += ongoingFee);                                             // 10% of interest
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal    += ongoingFee);                                             // 10% of interest
        assertEq(usdc.balanceOf(MAPLE_TREASURY), usdc_treasuryBal        += 0);
    }

    function setUp() external {
        /*******************************/
        /*** Set up actors and state ***/
        /*******************************/

        start = block.timestamp;

        // Set existing Orthogonal PD as Governor
        hevm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

        borrower = new Borrower();

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

        globals.setValidSubFactory(POOL_FACTORY, address(debtLockerFactory), true);  // Whitelist new DebtLockerFactory
    }

    function test_claim_onTimeInterestOnly() external {
        createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        fundLoan();
        drawdownLoan();

        // Make a single on time payment
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(1,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeInterestOnlySingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_lateInterestOnlySingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,true);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimePartiallyAmortized() external {
        createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        fundLoan();
        drawdownLoan();

        // Make a single on time payment
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(1,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimePartiallyAmortizedSingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_latePartiallyAmortizedSingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,true);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeFullyAmortized() external {
        createLoan(uint256(1_000_000 * USD), uint256(0));
        fundLoan();
        drawdownLoan();

        // Make a single on time payment
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(1,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = makeLoanPayments(1,false);
        totalPaid = principalPortion + interestPortion;

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeFullyAmortizedSingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(0));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_lateFullyAmortizedSingleClaim() external {
        createLoan(uint256(1_000_000 * USD), uint256(0));
        fundLoan();
        drawdownLoan();

        // Makeall three payments
        (uint256 principalPortion, uint256 interestPortion) = makeLoanPayments(3,false);
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_closedLoan() external {
        createLoan(uint256(1_000_000 * USD), uint256(0));
        fundLoan();
        drawdownLoan();

        (uint256 principalPortion, uint256 interestPortion) = closeLoan();
        uint256 totalPaid = principalPortion + interestPortion;

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], totalPaid);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        assertPoolState(principalPortion, interestPortion);

        // Fails to claim after loan is closed
        try pool.claim(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "able to claim"); } catch { }
    }
}