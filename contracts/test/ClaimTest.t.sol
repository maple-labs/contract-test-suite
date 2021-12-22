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

    function _createLoan(uint256 principalRequested, uint256 endingPrincipal) internal {
        address[2] memory assets = [WBTC, USDC];

        uint256[3] memory termDetails = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3)
        ];

        // 5 BTC @ ~$58k = $290k = 29% collateralized, interest only
        uint256[3] memory requests = [uint256(5 * BTC), principalRequested, endingPrincipal];  

        uint256[4] memory rates = [uint256(0.12e18), uint256(0.01e18), uint256(0.05e18), uint256(0.6e18)]; 

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));
    }

    function _fundLoan() internal {
        uint256 fundAmount       = 1_000_000 * USD;
        uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps

        pool.fundLoan(address(loanV2), address(debtLockerFactory), fundAmount);

        pool_principalOut       = pool.principalOut();
        pool_interestSum        = pool.interestSum();
        usdc_liquidityLockerBal = usdc.balanceOf(ORTHOGONAL_LL);
        usdc_stakeLockerBal     = usdc.balanceOf(ORTHOGONAL_SL);
        usdc_poolDelegateBal    = usdc.balanceOf(ORTHOGONAL_PD);
        usdc_treasuryBal        = usdc.balanceOf(MAPLE_TREASURY);
    }

    function _drawdownLoan() internal {
        uint256 fundAmount       = 1_000_000 * USD;
        uint256 establishmentFee = fundAmount * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps
        uint256 drawableFunds = fundAmount - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

        borrower.erc20_approve(WBTC, address(loanV2), 5 * BTC);
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));
    }

    function _makeLoanPayments(uint256 payments, bool late) internal returns (uint256 totalPrincipal,uint256 totalInterest) {

        for (uint256 i = 0; i < payments; i++) {
            hevm.warp(loanV2.nextPaymentDueDate() - 1 + (late ? 1 days: 0));

            // Check details for upcoming payment #1
            (uint256 principalPortion, uint256 interestPortion) = loanV2.getNextPaymentBreakdown();
            uint256 totalPayment = principalPortion + interestPortion;
            
            totalPrincipal += principalPortion;
            totalInterest  += interestPortion;

            // Make payment
            erc20_mint(USDC, 9, address(borrower), totalPayment);
            borrower.erc20_approve(USDC, address(loanV2), totalPayment);
            borrower.loan_makePayment(address(loanV2), totalPayment);
        }
    }

    function _closeLoan() internal returns(uint256 principalPortion, uint256 feePortion) {
        hevm.warp(block.timestamp + 5 days);

        principalPortion = loanV2.principal();
        feePortion       = principalPortion * loanV2.earlyFeeRate() * USD / uint256(10 ** 24); // 1% on the principal 
        
        uint256 totalPayment = principalPortion + feePortion;

        // Close loan, paying a flat fee on principal
        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV2), totalPayment);
        borrower.loan_closeLoan(address(loanV2), totalPayment);
    }

    function _assertPoolState( uint256 principalPortion, uint256 interestPortion ) internal {
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
        _createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Make a single on time payment
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(1, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);       

        assertEq(details[0], 986_301_3698);
        assertEq(details[1], 986_301_3698);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        _assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 986_301_3698);
        assertEq(details[1], 986_301_3698);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        _assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_009_863_013_698);
        assertEq(details[1],      986_301_3698);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeInterestOnlySingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_029_589_041_094);
        assertEq(details[1],    295_890_41_094);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_lateInterestOnlySingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(1_000_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, true);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_185_506_849_311);
        assertEq(details[1],   185_506_849_311);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimePartiallyAmortized() external {
        _createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Make a single on time payment
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(1, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 174_896_600_402);
        assertEq(details[1],   9_863_013_698);
        assertEq(details[2], 165_033_586_704);
        assertEq(details[3],               0);
        assertEq(details[4],               0);
        assertEq(details[5],               0);
        assertEq(details[6],               0);

        _assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 174_896_600_402);
        assertEq(details[1],   8_235_285_172);
        assertEq(details[2], 166_661_315_230);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        _assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 674_896_600_403);
        assertEq(details[1],   6_591_502_337);
        assertEq(details[2], 668_305_098_066);
        assertEq(details[3],               0);
        assertEq(details[4],               0);
        assertEq(details[5],               0);
        assertEq(details[6],               0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimePartiallyAmortizedSingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_024_689_801_207);
        assertEq(details[1],    24_689_801_207);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_latePartiallyAmortizedSingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(500_000 * USD));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, true);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_154_791_337_014);
        assertEq(details[1],   154_791_337_014);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeFullyAmortized() external {
        _createLoan(uint256(1_000_000 * USD), uint256(0));
        _fundLoan();
        _drawdownLoan();

        // Make a single on time payment
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(1, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 339_930_187_106);
        assertEq(details[1],   9_863_013_698);
        assertEq(details[2], 330_067_173_408);
        assertEq(details[3],               0);
        assertEq(details[4],               0);
        assertEq(details[5],               0);
        assertEq(details[6],               0);

        _assertPoolState(principalPortion, interestPortion);

        // Make another payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 339_930_187_106);
        assertEq(details[1],   6_607_556_645);
        assertEq(details[2], 333_322_630_461);
        assertEq(details[3],               0);
        assertEq(details[4],               0);
        assertEq(details[5],               0);
        assertEq(details[6],               0);

        _assertPoolState(principalPortion, interestPortion);

        // Make last payment
        ( principalPortion, interestPortion ) = _makeLoanPayments(1, false);

        details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 339_930_187_106);
        assertEq(details[1],   3_319_990_975);
        assertEq(details[2], 336_610_196_131);
        assertEq(details[3],               0);
        assertEq(details[4],               0);
        assertEq(details[5],               0);
        assertEq(details[6],               0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_onTimeFullyAmortizedSingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(0));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_019_790_561_318);
        assertEq(details[1],    19_790_561_318);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_lateFullyAmortizedSingleClaim() external {
        _createLoan(uint256(1_000_000 * USD), uint256(0));
        _fundLoan();
        _drawdownLoan();

        // Makeall three payments
        ( uint256 principalPortion, uint256 interestPortion ) = _makeLoanPayments(3, false);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        assertEq(details[0], 1_019_790_561_318);
        assertEq(details[1],    19_790_561_318);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);
    }

    function test_claim_closedLoan() external {
        _createLoan(uint256(1_000_000 * USD), uint256(0));
        _fundLoan();
        _drawdownLoan();

        ( uint256 principalPortion, uint256 interestPortion ) = _closeLoan();

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV2)), 0);
    
        assertEq(details[0], 1_010_000_000_000);
        assertEq(details[1],    10_000_000_000);
        assertEq(details[2], 1_000_000_000_000);
        assertEq(details[3],                 0);
        assertEq(details[4],                 0);
        assertEq(details[5],                 0);
        assertEq(details[6],                 0);

        _assertPoolState(principalPortion, interestPortion);

        // Fails to claim after loan is closed
        try pool.claim(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "Able to claim"); } catch { }
    }
}
