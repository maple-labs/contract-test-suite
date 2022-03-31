// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/contracts/interfaces/IERC20.sol";

import { TestUtils } from "../../modules/contract-test-utils/contracts/test.sol";

import { DebtLocker }            from "../../modules/debt-locker-v3/contracts/DebtLocker.sol";
import { DebtLockerFactory }     from "../../modules/debt-locker-v3/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker-v3/contracts/DebtLockerInitializer.sol";

import { IMapleLoan } from "../../modules/loan-v3/contracts/interfaces/IMapleLoan.sol";

import { MapleLoan }            from "../../modules/loan-v3/contracts/MapleLoan.sol";
import { MapleLoanFactory }     from "../../modules/loan-v3/contracts/MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../../modules/loan-v3/contracts/MapleLoanInitializer.sol";
import { Refinancer }           from "../../modules/loan-v3/contracts/Refinancer.sol";

import { Borrower } from "./accounts/Borrower.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

import { IMapleGlobalsLike, IPoolLike } from "./interfaces/Interfaces.sol";

contract RefinanceTest is AddressRegistry, TestUtils {

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
    uint256 deadline;

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

    IMapleLoan loanV3;

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
        vm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

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
        assertTrue(globals.isValidSubFactory(POOL_FACTORY, address(debtLockerFactory), 1));

        refinancer = new Refinancer();

        /*********************/
        /*** Deploy LoanV3 ***/
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

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV3 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));

        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 fundAmount = 1_000_000 * USD;

        assertEq(usdc.balanceOf(address(loanV3)), 0);

        pool.fundLoan(address(loanV3), address(debtLockerFactory), fundAmount);

        /*********************/
        /*** Drawdown Loan ***/
        /*********************/

        erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

        borrower.erc20_approve(WBTC, address(loanV3), 5 * BTC);
        borrower.loan_drawdownFunds(address(loanV3), fundAmount, address(borrower));

        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        vm.warp(loanV3.nextPaymentDueDate());

        deadline = block.timestamp + 10 days;

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 delegateFee, uint256 treasuryFee ) = loanV3.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);
        assertEq(delegateFee,      205_479452);
        assertEq(treasuryFee,      205_479452);

        uint256 totalPayment = interestPortion + delegateFee + treasuryFee;

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV3), totalPayment);
        borrower.loan_makePayment(address(loanV3), totalPayment);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV3), address(debtLockerFactory));

        assertEq(loanV3.principal(),           1_000_000_000000);
        assertEq(loanV3.endingPrincipal(),     1_000_000_000000);
        assertEq(loanV3.interestRate(),        0.12e18);
        assertEq(loanV3.paymentsRemaining(),   2);
        assertEq(loanV3.paymentInterval(),     30 days);
        assertEq(loanV3.delegateFee(),         205_479452);
        assertEq(loanV3.treasuryFee(),         205_479452);
        assertEq(loanV3.refinanceCommitment(), 0);
        assertEq(loanV3.drawableFunds(),       0);
        assertEq(loanV3.claimableFunds(),      0);

        usdc_liquidityLockerBal = usdc.balanceOf(pool.liquidityLocker());
        pool_principalOut       = pool.principalOut();
    }

    function test_refinance_multipleActions() external {

        /*****************/
        /*** Refinance ***/
        /*****************/

        uint256[3] memory refinanceTermDetails = [
            uint256(15 days),  // 15 day grace period
            uint256(45 days),  // 45 day payment interval
            uint256(3)
        ];

        uint256[3] memory requests = [uint256(5 * BTC), uint256(1_000_000 * USD), uint256(1_000_000 * USD)];

        // 2 BTC @ ~$58k = $116k = 11.6% collateralized, partially amortized
        uint256[3] memory refinanceRequests = [uint256(2 * BTC), uint256(2_000_000 * USD), uint256(1_000_000 * USD)];
        uint256[4] memory refinanceRates    = [uint256(0.10e18), uint256(0), uint256(0.04e18), uint256(0.4e18)];

        uint256 principalIncrease = refinanceRequests[1] - requests[1];

        {
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

            borrower.loan_proposeNewTerms(address(loanV3), address(refinancer), block.timestamp + 10 days, data);

            // Pool Delegate(address this) accepts new terms on Debt Locker
            DebtLocker debtLocker = DebtLocker(loanV3.lender());

            // Fails if there're no extra funds from pool
            try debtLocker.acceptNewTerms(address(refinancer), block.timestamp + 10 days, data, principalIncrease) { assertTrue(false, "shouldn't succeed"); } catch { }

            // Pool Delegate funds loan again for increasing amount
            pool.fundLoan(address(loanV3), address(debtLockerFactory), principalIncrease);

            debtLocker.acceptNewTerms(address(refinancer), block.timestamp + 10 days, data, principalIncrease);
        }

        assertEq(loanV3.gracePeriod(),       refinanceTermDetails[0]);
        assertEq(loanV3.paymentInterval(),   refinanceTermDetails[1]);
        assertEq(loanV3.paymentsRemaining(), refinanceTermDetails[2]);

        assertEq(loanV3.principalRequested(), requests[1] + principalIncrease);
        assertEq(loanV3.principal(),          requests[1] + principalIncrease);
        assertEq(loanV3.collateralRequired(), refinanceRequests[0]);

        assertEq(loanV3.interestRate(),        refinanceRates[0]);
        assertEq(loanV3.lateFeeRate(),         refinanceRates[2]);
        assertEq(loanV3.lateInterestPremium(), refinanceRates[3]);

        /****************************/
        /*** Make Another payment ***/
        /****************************/

        // Drawdown extra amount
        borrower.loan_drawdownFunds(address(loanV3), principalIncrease, address(borrower));

        vm.warp(loanV3.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion, uint256 delegateFee, uint256 treasuryFee ) = loanV3.getNextPaymentBreakdown();

        // Principal is non-zero since the loan is now partially amortized
        assertEq(principalPortion, 329_257_314375);
        assertEq(interestPortion,  24_657_534246);
        assertEq(delegateFee,      616_438356);
        assertEq(treasuryFee,      616_438356);

        uint256 totalPayment = principalPortion + interestPortion + delegateFee + treasuryFee;

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV3), totalPayment);
        borrower.loan_makePayment(address(loanV3), totalPayment);

        assertEq(loanV3.drawableFunds(),      0);
        assertEq(loanV3.claimableFunds(),     interestPortion + principalPortion);
        assertEq(loanV3.nextPaymentDueDate(), block.timestamp + 45 days);
        assertEq(loanV3.principal(),          2_000_000 * USD - principalPortion);
        assertEq(loanV3.paymentsRemaining(),  2);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        uint256[7] memory details = pool.claim(address(loanV3), address(debtLockerFactory));

        assertEq(usdc.balanceOf(address(loanV3)), 0);

        assertEq(details[0], principalPortion + interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], principalPortion);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);
    }

    function test_refinance_samePrincipal() external {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(Refinancer.setPaymentsRemaining.selector, 6);

        borrower.loan_proposeNewTerms(address(loanV3), address(refinancer), deadline, calls);
        DebtLocker(loanV3.lender()).acceptNewTerms(address(refinancer), deadline, calls, 0);

        assertEq(loanV3.principal(),           1_000_000_000000);
        assertEq(loanV3.endingPrincipal(),     1_000_000_000000);
        assertEq(loanV3.interestRate(),        0.12e18);
        assertEq(loanV3.paymentsRemaining(),   6);
        assertEq(loanV3.paymentInterval(),     30 days);
        assertEq(loanV3.delegateFee(),         205_479452);  // 1,000,000 * 0.5% * 30 / 365
        assertEq(loanV3.treasuryFee(),         205_479452);
        assertEq(loanV3.refinanceCommitment(), 0);
        assertEq(loanV3.drawableFunds(),       0);
        assertEq(loanV3.claimableFunds(),      0);

        vm.warp(start + 60 days);

        ( uint256 principalPortion, uint256 interestPortion, uint256 delegateFee, uint256 treasuryFee ) = loanV3.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9_863_013698); // 1,000,000 * 12% * 30 / 365
        assertEq(delegateFee,      205_479452);
        assertEq(treasuryFee,      205_479452);

        uint256 totalPayment = principalPortion + interestPortion + delegateFee + treasuryFee;

        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV3), totalPayment);
        borrower.loan_makePayment(address(loanV3), totalPayment);

        assertEq(loanV3.drawableFunds(),      0);
        assertEq(loanV3.claimableFunds(),     interestPortion);
        assertEq(loanV3.nextPaymentDueDate(), start + 90 days);
        assertEq(loanV3.principal(),          1_000_000_000000);
        assertEq(loanV3.paymentsRemaining(),  5);

        assertEq(usdc.balanceOf(address(loanV3)), interestPortion);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);

        uint256[7] memory details = pool.claim(address(loanV3), address(debtLockerFactory));
        usdc_liquidityLockerBal += 0.8e18 * interestPortion / 1e18 + 2;

        assertEq(usdc.balanceOf(address(loanV3)), 0);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);
        
        assertEq(details[0], interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);
    }

    function test_refinance_increasedPrincipal() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Refinancer.increasePrincipal.selector,  1_000_000_000000);
        calls[1] = abi.encodeWithSelector(Refinancer.setEndingPrincipal.selector, 2_000_000_000000);

        borrower.loan_proposeNewTerms(address(loanV3), address(refinancer), deadline, calls);
        pool.fundLoan(address(loanV3), address(debtLockerFactory), 1_000_000_000000);
        usdc_liquidityLockerBal -= 1_000_000_000000;
        DebtLocker(loanV3.lender()).acceptNewTerms(address(refinancer), deadline, calls, 1_000_000_000000);

        assertEq(loanV3.principal(),           2_000_000_000000);
        assertEq(loanV3.endingPrincipal(),     2_000_000_000000);
        assertEq(loanV3.interestRate(),        0.12e18);
        assertEq(loanV3.paymentsRemaining(),   2);
        assertEq(loanV3.paymentInterval(),     30 days);
        assertEq(loanV3.delegateFee(),         410_958904);  // 2,000,000 * 0.5% * 30 / 365
        assertEq(loanV3.treasuryFee(),         410_958904);
        assertEq(loanV3.refinanceCommitment(), 0);
        assertEq(loanV3.drawableFunds(),       1_000_000_000000);
        assertEq(loanV3.claimableFunds(),      0);

        borrower.loan_drawdownFunds(address(loanV3), 1_000_000_000000, address(borrower));

        vm.warp(start + 60 days);

        ( uint256 principalPortion, uint256 interestPortion, uint256 delegateFee, uint256 treasuryFee ) = loanV3.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  19_726_027397); // 2,000,000 * 12% * 30 / 365
        assertEq(delegateFee,      410_958904);
        assertEq(treasuryFee,      410_958904);

        uint256 totalPayment = principalPortion + interestPortion + delegateFee + treasuryFee;

        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV3), totalPayment);
        borrower.loan_makePayment(address(loanV3), totalPayment);

        assertEq(loanV3.drawableFunds(),      0);
        assertEq(loanV3.claimableFunds(),     interestPortion);
        assertEq(loanV3.nextPaymentDueDate(), start + 90 days);
        assertEq(loanV3.principal(),          2_000_000_000000);
        assertEq(loanV3.paymentsRemaining(),  1);
        
        assertEq(usdc.balanceOf(address(loanV3)), interestPortion);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut + 1_000_000_000000);

        uint256[7] memory details = pool.claim(address(loanV3), address(debtLockerFactory));
        usdc_liquidityLockerBal += 0.8e18 * interestPortion / 1e18 + 2;

        assertEq(usdc.balanceOf(address(loanV3)), 0);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut + 1_000_000_000000);

        assertEq(details[0], interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);
    }

    function test_refinance_decreasedPrincipal() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(Refinancer.setEndingPrincipal.selector, 750_000_000000);
        calls[1] = abi.encodeWithSelector(Refinancer.decreasePrincipal.selector,  250_000_000000);

        borrower.loan_proposeNewTerms(address(loanV3), address(refinancer), deadline, calls);

        erc20_mint(USDC, 9, address(borrower), 250_000_000000);

        borrower.erc20_approve(USDC, address(loanV3), 250_000_000000);
        borrower.loan_returnFunds(address(loanV3), 250_000_000000);

        DebtLocker(loanV3.lender()).acceptNewTerms(address(refinancer), deadline, calls, 0);

        assertEq(loanV3.principal(),           750_000_000000);
        assertEq(loanV3.endingPrincipal(),     750_000_000000);
        assertEq(loanV3.interestRate(),        0.12e18);
        assertEq(loanV3.paymentsRemaining(),   2);
        assertEq(loanV3.paymentInterval(),     30 days);
        assertEq(loanV3.delegateFee(),         154_109589);  // 750,000 * 0.5% * 30 / 365
        assertEq(loanV3.treasuryFee(),         154_109589);
        assertEq(loanV3.refinanceCommitment(), 0);
        assertEq(loanV3.drawableFunds(),       0);
        assertEq(loanV3.claimableFunds(),      250_000_000000);

        assertEq(usdc.balanceOf(address(loanV3)), 250_000_000000);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);

        uint256[7] memory details = pool.claim(address(loanV3), address(debtLockerFactory));
        usdc_liquidityLockerBal += 200_000_000000;

        assertEq(usdc.balanceOf(address(loanV3)), 0);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);
        
        assertEq(details[0], 250_000_000000);
        assertEq(details[1], 250_000_000000);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);

        vm.warp(start + 60 days);

        ( uint256 principalPortion, uint256 interestPortion, uint256 delegateFee, uint256 treasuryFee ) = loanV3.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  7_397_260273); // 750,000 * 12% * 30 / 365
        assertEq(delegateFee,      154_109589);
        assertEq(treasuryFee,      154_109589);

        uint256 totalPayment = principalPortion + interestPortion + delegateFee + treasuryFee;

        erc20_mint(USDC, 9, address(borrower), totalPayment);

        borrower.erc20_approve(USDC, address(loanV3), totalPayment);
        borrower.loan_makePayment(address(loanV3), totalPayment);

        assertEq(loanV3.drawableFunds(),      0);
        assertEq(loanV3.claimableFunds(),     interestPortion);
        assertEq(loanV3.nextPaymentDueDate(), start + 90 days);
        assertEq(loanV3.principal(),          750_000_000000);
        assertEq(loanV3.paymentsRemaining(),  1);

        assertEq(usdc.balanceOf(address(loanV3)), interestPortion);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);

        details = pool.claim(address(loanV3), address(debtLockerFactory));
        usdc_liquidityLockerBal += 0.8e18 * interestPortion / 1e18 + 1;

        assertEq(usdc.balanceOf(address(loanV3)), 0);
        assertEq(usdc.balanceOf(pool.liquidityLocker()), usdc_liquidityLockerBal);
        assertEq(pool.principalOut(), pool_principalOut);

        assertEq(details[0], interestPortion);
        assertEq(details[1], interestPortion);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], 0);
        assertEq(details[6], 0);
    }

}
