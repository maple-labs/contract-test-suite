// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/src/interfaces/IERC20.sol";

import { TestUtils, StateManipulations } from "../../modules/contract-test-utils/contracts/test.sol";

import { MapleProxyFactory } from "../../modules/debt-locker/modules/maple-proxy-factory/contracts/MapleProxyFactory.sol";  // TODO: Import MPF

import { DebtLocker }            from "../../modules/debt-locker/contracts/DebtLocker.sol";
import { DebtLockerFactory }     from "../../modules/debt-locker/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker/contracts/DebtLockerInitializer.sol";

import { Liquidator }        from "../../modules/liquidations/contracts/Liquidator.sol";
import { Rebalancer }        from "../../modules/liquidations/contracts/test/mocks/Mocks.sol";
import { SushiswapStrategy } from "../../modules/liquidations/contracts/SushiswapStrategy.sol";
import { UniswapV2Strategy } from "../../modules/liquidations/contracts/UniswapV2Strategy.sol";

import { IMapleLoan } from "../../modules/loan/contracts/interfaces/IMapleLoan.sol";

import { MapleLoan }            from "../../modules/loan/contracts/MapleLoan.sol";
import { MapleLoanFactory }     from "../../modules/loan/contracts/MapleLoanFactory.sol";
import { MapleLoanInitializer } from "../../modules/loan/contracts/MapleLoanInitializer.sol";

import {
    ILoanV1Like,
    IMapleGlobalsLike,
    IPoolLibLike,
    IPoolLike,
    IStakeLockerLike
} from "./interfaces/Interfaces.sol";

import { Borrower } from "./accounts/Borrower.sol";
import { Keeper }   from "./accounts/Keeper.sol";
import { Lender }   from "./accounts/Lender.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

contract ParityTest is AddressRegistry, StateManipulations, TestUtils {

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

        globals.setValidSubFactory(POOL_FACTORY, address(debtLockerFactory), true);  // Whitelist new DebtLockerFactory
    }

    function test_endToEndLoan() external {

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
        uint256 drawableFunds = fundAmount - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 5 * BTC);

        assertEq(loanV2.drawableFunds(),            drawableFunds);
        assertEq(usdc.balanceOf(address(loanV2)),   drawableFunds);
        assertEq(usdc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(borrower)), 5 * BTC);
        assertEq(wbtc.balanceOf(address(loanV2)),   0);
        assertEq(loanV2.collateral(),               0);

        borrower.erc20_transfer(WBTC, address(loanV2), 5 * BTC);
        borrower.loan_postCollateral(address(loanV2), 0);
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));

        assertEq(loanV2.drawableFunds(),            0);
        assertEq(usdc.balanceOf(address(loanV2)),   0);
        assertEq(usdc.balanceOf(address(borrower)), drawableFunds);
        assertEq(wbtc.balanceOf(address(borrower)), 0);
        assertEq(wbtc.balanceOf(address(loanV2)),   5 * BTC);
        assertEq(loanV2.collateral(),               5 * BTC);
        
        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     0);
        assertEq(loanV2.nextPaymentDueDate(), start + 30 days);
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  3);

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        // Make first payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);
        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

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
        ( principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        assertEq(principalPortion, 0);
        assertEq(interestPortion,  9863_013698);  // Interest + 1972_602739

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     0);                // Claim has been made
        assertEq(loanV2.nextPaymentDueDate(), start + 60 days);  // Payment 2 due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  2);

        assertEq(usdc.balanceOf(address(loanV2)), 0);

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);
        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

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
        ( principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        assertEq(principalPortion, 1_000_000 * USD);
        assertEq(interestPortion,  9863_013698);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     interestPortion);
        assertEq(loanV2.nextPaymentDueDate(), start + 90 days);  // Payment 3 due date
        assertEq(loanV2.principal(),          1_000_000 * USD);
        assertEq(loanV2.paymentsRemaining(),  1);

        assertEq(usdc.balanceOf(address(loanV2)), interestPortion);

        // Make third payment
        erc20_mint(USDC, 9, address(borrower), 1_009_863_013698);  // Principal + interest
        borrower.erc20_transfer(USDC, address(loanV2), 1_009_863_013698);
        borrower.loan_makePayment(address(loanV2), 0);

        assertEq(loanV2.drawableFunds(),      0);
        assertEq(loanV2.claimableFunds(),     1_000_000 * USD + interestPortion * 2);
        assertEq(loanV2.nextPaymentDueDate(), 0); 
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

    function test_triggerDefault_overCollateralized() external {

        /*********************/
        /*** Deploy LoanV2 ***/
        /*********************/

        address[2] memory assets = [WBTC, USDC];

        uint256[3] memory termDetails = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3)
        ];

        // 25 BTC @ $58k = $1.45m = 145% collateralized, interest only
        uint256[3] memory requests = [uint256(25 * BTC), uint256(1_000_000 * USD), uint256(1_000_000 * USD)];  

        uint256[4] memory rates = [uint256(0.12e18), uint256(0), uint256(0), uint256(0.6e18)];

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));

        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 totalPrincipal   = 1_000_000 * USD;
        uint256 establishmentFee = totalPrincipal * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps
        
        pool.fundLoan(address(loanV2), address(debtLockerFactory), totalPrincipal);
        
        /*********************/
        /*** Drawdown Loan ***/
        /*********************/

        uint256 drawableFunds = totalPrincipal - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 25 * BTC);

        borrower.erc20_transfer(WBTC, address(loanV2), 25 * BTC);
        borrower.loan_postCollateral(address(loanV2), 0);
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));
        
        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( uint256 principalPortion, uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();
        // Make first payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV2), address(debtLockerFactory));

        /********************************/
        /*** Make Payment 2 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #2
        ( principalPortion, interestPortion ) = loanV2.getNextPaymentBreakdown();

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        /*******************************/
        /*** Borrower Misses Payment ***/
        /*******************************/

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod() + 1);

        /**********************************************/
        /*** Pool Delegate tries to trigger default ***/
        /**********************************************/

        try pool.triggerDefault(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "Trigger default before claim"); } catch {}

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV2), address(debtLockerFactory));

        /**************************************/
        /*** Pool Delegate triggers default ***/
        /**************************************/

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod());

        try pool.triggerDefault(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "Trigger default before in default"); } catch {}

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod() + 1);

        DebtLocker debtLocker = DebtLocker(pool.debtLockers(address(loanV2), address(debtLockerFactory)));

        // Loan State
        assertEq(loanV2.drawableFunds(),      0);     
        assertEq(loanV2.claimableFunds(),     0);    
        assertEq(loanV2.collateral(),         25 * BTC);        
        assertEq(loanV2.lender(),             address(debtLocker));            
        assertEq(loanV2.nextPaymentDueDate(), start + 90 days);
        assertEq(loanV2.paymentsRemaining(),  1); 
        assertEq(loanV2.principal(),          1_000_000 * USD);         

        // DebtLocker State
        assertTrue( debtLocker.liquidator() == address(0));
        assertTrue(!debtLocker.repossessed());

        // USDC/WBTC State
        assertEq(usdc.balanceOf(address(loanV2)),     0);
        assertEq(usdc.balanceOf(address(debtLocker)), 0);
        assertEq(wbtc.balanceOf(address(loanV2)),     25 * BTC);
        assertEq(wbtc.balanceOf(address(debtLocker)), 0);

        pool.triggerDefault(address(loanV2), address(debtLockerFactory));

        // Loan State
        assertEq(loanV2.drawableFunds(),      0);     
        assertEq(loanV2.claimableFunds(),     0);    
        assertEq(loanV2.collateral(),         0);        
        assertEq(loanV2.lender(),             address(debtLocker));            
        assertEq(loanV2.nextPaymentDueDate(), 0);
        assertEq(loanV2.paymentsRemaining(),  0); 
        assertEq(loanV2.principal(),          0); 

        // DebtLocker State
        assertTrue(debtLocker.liquidator() != address(0));
        assertTrue(debtLocker.repossessed());

        // USDC/WBTC State
        assertEq(usdc.balanceOf(address(loanV2)),                  0);
        assertEq(usdc.balanceOf(address(debtLocker)),              0);
        assertEq(wbtc.balanceOf(address(loanV2)),                  0);
        assertEq(wbtc.balanceOf(address(debtLocker)),              0);
        assertEq(wbtc.balanceOf(address(debtLocker.liquidator())), 25 * BTC);

        /*******************************************************/
        /*** Pool Delegate configures liquidation parameters ***/
        /*******************************************************/

        // Note: This should be part of liquidation UX in webapp for PoolDelegate

        debtLocker.setAllowedSlippage(300);        // 3% slippage allowed
        debtLocker.setMinRatio(40_000 * 10 ** 6);  // Minimum 40k USDC per WBTC (Market price is ~43k at block 13276702)

        /**********************************/
        /*** Collateral gets liquidated ***/
        /**********************************/
        {
            Keeper keeper1 = new Keeper();
            Keeper keeper2 = new Keeper();

            SushiswapStrategy sushiswapStrategy = new SushiswapStrategy();
            UniswapV2Strategy uniswapV2Strategy = new UniswapV2Strategy();

            Liquidator liquidator = Liquidator(debtLocker.liquidator());

            Rebalancer rebalancer = new Rebalancer();

            erc20_mint(USDC, 9, address(rebalancer), type(uint256).max);  // Mint "infinite" USDC into rebalancer for simulating arbitrage

            assertEq(wbtc.balanceOf(address(liquidator)), 25 * BTC);
            assertEq(usdc.balanceOf(address(liquidator)), 0);
            assertEq(usdc.balanceOf(address(debtLocker)), 0);
            assertEq(usdc.balanceOf(address(keeper1)),    0);
            assertEq(usdc.balanceOf(address(keeper2)),    0);

            assertEq(globals.getLatestPrice(WBTC),            58_975_92000000);  // $58,975.92/WBTC market price
            assertEq(liquidator.getExpectedAmount(25 * BTC), 1_430_166_060000);  // $57,206.64/WBTC sale price (97% of market price)

            // Perform liquidation swaps from each keeper
            keeper1.strategy_flashBorrowLiquidation(
                address(sushiswapStrategy), 
                address(debtLocker.liquidator()), 
                10 * BTC, 
                type(uint256).max,
                WBTC, 
                WETH, 
                USDC, 
                address(keeper1)
            );

            keeper2.strategy_flashBorrowLiquidation(
                address(uniswapV2Strategy), 
                address(debtLocker.liquidator()), 
                15 * BTC, 
                type(uint256).max,
                WBTC, 
                WETH, 
                USDC, 
                address(keeper2)
            );
            
            assertEq(wbtc.balanceOf(address(liquidator)), 0);
            assertEq(usdc.balanceOf(address(liquidator)), 0);
            assertEq(usdc.balanceOf(address(debtLocker)), 1_430_166_060000);  // Same value as `getExpectedAmount`
            assertEq(usdc.balanceOf(address(keeper1)),    8_994_323176);      // Keeper profits
            assertEq(usdc.balanceOf(address(keeper2)),    7_393_611120);      // Keeper profits
        }

        /***************************************************************/
        /*** Pool delegate claims funds, triggering BPT burning flow ***/
        /***************************************************************/

        // Before state
        bpt_stakeLockerBal      = bpt.balanceOf(ORTHOGONAL_SL);
        pool_principalOut       = pool.principalOut();
        pool_interestSum        = pool.interestSum();
        usdc_liquidityLockerBal = usdc.balanceOf(ORTHOGONAL_LL);
        usdc_stakeLockerBal     = usdc.balanceOf(ORTHOGONAL_SL);
        usdc_poolDelegateBal    = usdc.balanceOf(ORTHOGONAL_PD);

        IStakeLockerLike stakeLocker = IStakeLockerLike(ORTHOGONAL_SL);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        uint256 totalRecovered          = 1_430_166_060000;  // Recovered from liquidation
        uint256 interestFromLiquidation = 430_166_060000;    // totalRecovered - 1m
        
        uint256 ongoingFee = interestFromLiquidation * 1000 / 10_000;  // Applies to both StakeLocker and Pool Delegate since both have 10% ongoing fees

        assertEq(details[0], totalRecovered);           // Total funds recovered
        assertEq(details[1], interestFromLiquidation);  // Extra funds registered as interest
        assertEq(details[2], 0);                        // No principal
        assertEq(details[3], 0);                        // No establishment fee
        assertEq(details[4], 0);                        // No excess
        assertEq(details[5], totalPrincipal);           // Total recovered fully covers principal, rest goes to interest
        assertEq(details[6], 0);                        // No default suffered

        assertEq(bpt.balanceOf(ORTHOGONAL_SL),   bpt_stakeLockerBal);                                           // Max amount of BPTs were burned
        assertEq(pool.principalOut(),            pool_principalOut - totalPrincipal);                           // Principal out reduced by full amount
        assertEq(pool.interestSum(),             pool_interestSum + interestFromLiquidation - ongoingFee * 2);  // Interest increased by 80% of interest "earned" from liquidation
        assertEq(pool.poolLosses(),              0);                                                            // Shortfall from liquidation - BPT recovery (zero before)
        assertEq(stakeLocker.bptLosses(),        0);                                                            // BPTs burned (zero before)
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal + totalRecovered - ongoingFee * 2);    // Liquidation recovery + BPT recovery minus PD and SL interest portions
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),  usdc_stakeLockerBal + ongoingFee);                             // Liquidation recovery + BPT recovery
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),  usdc_poolDelegateBal + ongoingFee);                            // Liquidation recovery + BPT recovery
    }

    function test_triggerDefault_underCollateralized() external {

        /*********************/
        /*** Deploy LoanV2 ***/
        /*********************/

        address[2] memory assets = [WBTC, USDC];

        uint256[3] memory termDetails = [
            uint256(10 days),  // 10 day grace period
            uint256(30 days),  // 30 day payment interval
            uint256(3)
        ];

        // 250 BTC @ $58k = $14.5m = 14.5% collateralized, interest only
        uint256[3] memory requests = [uint256(250 * BTC), uint256(100_000_000 * USD), uint256(100_000_000 * USD)];  

        uint256[4] memory rates = [uint256(0.12e18), uint256(0), uint256(0), uint256(0.6e18)];

        bytes memory arguments = loanInitializer.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loanV2 = IMapleLoan(borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt));

        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 totalPrincipal   = 100_000_000 * USD;
        uint256 establishmentFee = totalPrincipal * 25 * 90 / 365 / 10_000;  // Investor fee and treasury fee are both 25bps

        // Mint and deposit extra funds to raise liquidity locker balance
        pool.setLiquidityCap(pool.liquidityCap() + totalPrincipal);
        erc20_mint(USDC, 9, address(this), totalPrincipal);
        usdc.approve(address(pool), totalPrincipal);
        pool.deposit(totalPrincipal);  
        
        pool.fundLoan(address(loanV2), address(debtLockerFactory), totalPrincipal);
        
        /*********************/
        /*** Drawdown Loan ***/
        /*********************/

        uint256 drawableFunds = totalPrincipal - establishmentFee * 2;

        erc20_mint(WBTC, 0, address(borrower), 250 * BTC);

        borrower.erc20_transfer(WBTC, address(loanV2), 250 * BTC);
        borrower.loan_postCollateral(address(loanV2), 0);
        borrower.loan_drawdownFunds(address(loanV2), drawableFunds, address(borrower));
        
        /********************************/
        /*** Make Payment 1 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #1
        ( , uint256 interestPortion ) = loanV2.getNextPaymentBreakdown();
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV2), address(debtLockerFactory));

        /********************************/
        /*** Make Payment 2 (On time) ***/
        /********************************/

        hevm.warp(loanV2.nextPaymentDueDate());

        // Check details for upcoming payment #2
        ( , interestPortion ) = loanV2.getNextPaymentBreakdown();

        // Make second payment
        erc20_mint(USDC, 9, address(borrower), interestPortion);

        borrower.erc20_transfer(USDC, address(loanV2), interestPortion);
        borrower.loan_makePayment(address(loanV2), 0);

        /*******************************/
        /*** Borrower Misses Payment ***/
        /*******************************/

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod() + 1);

        /**********************************************/
        /*** Pool Delegate tries to trigger default ***/
        /**********************************************/

        try pool.triggerDefault(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "Trigger default before claim"); } catch {}

        /************************************/
        /*** Claim Funds as Pool Delegate ***/
        /************************************/

        pool.claim(address(loanV2), address(debtLockerFactory));

        /**************************************/
        /*** Pool Delegate triggers default ***/
        /**************************************/

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod());

        try pool.triggerDefault(address(loanV2), address(debtLockerFactory)) { assertTrue(false, "Trigger default before in default"); } catch {}

        hevm.warp(loanV2.nextPaymentDueDate() + loanV2.gracePeriod() + 1);

        DebtLocker debtLocker = DebtLocker(pool.debtLockers(address(loanV2), address(debtLockerFactory)));

        // Loan State
        assertEq(loanV2.drawableFunds(),      0);     
        assertEq(loanV2.claimableFunds(),     0);    
        assertEq(loanV2.collateral(),         250 * BTC);        
        assertEq(loanV2.lender(),             address(debtLocker));            
        assertEq(loanV2.nextPaymentDueDate(), start + 90 days);
        assertEq(loanV2.paymentsRemaining(),  1); 
        assertEq(loanV2.principal(),          100_000_000 * USD);         

        // DebtLocker State
        assertTrue( debtLocker.liquidator() == address(0));
        assertTrue(!debtLocker.repossessed());

        // USDC/WBTC State
        assertEq(usdc.balanceOf(address(loanV2)),     0);
        assertEq(usdc.balanceOf(address(debtLocker)), 0);
        assertEq(wbtc.balanceOf(address(loanV2)),     250 * BTC);
        assertEq(wbtc.balanceOf(address(debtLocker)), 0);

        pool.triggerDefault(address(loanV2), address(debtLockerFactory));

        // Loan State
        assertEq(loanV2.drawableFunds(),      0);     
        assertEq(loanV2.claimableFunds(),     0);    
        assertEq(loanV2.collateral(),         0);        
        assertEq(loanV2.lender(),             address(debtLocker));            
        assertEq(loanV2.nextPaymentDueDate(), 0);
        assertEq(loanV2.paymentsRemaining(),  0); 
        assertEq(loanV2.principal(),          0); 

        // DebtLocker State
        assertTrue(debtLocker.liquidator() != address(0));
        assertTrue(debtLocker.repossessed());

        // USDC/WBTC State
        assertEq(usdc.balanceOf(address(loanV2)),                  0);
        assertEq(usdc.balanceOf(address(debtLocker)),              0);
        assertEq(wbtc.balanceOf(address(loanV2)),                  0);
        assertEq(wbtc.balanceOf(address(debtLocker)),              0);
        assertEq(wbtc.balanceOf(address(debtLocker.liquidator())), 250 * BTC);

        /*******************************************************/
        /*** Pool Delegate configures liquidation parameters ***/
        /*******************************************************/

        // Note: This should be part of liquidation UX in webapp for PoolDelegate

        debtLocker.setAllowedSlippage(300);        // 3% slippage allowed
        debtLocker.setMinRatio(40_000 * 10 ** 6);  // Minimum 40k USDC per WBTC (Market price is ~43k at block 13276702)

        /**********************************/
        /*** Collateral gets liquidated ***/
        /**********************************/
        {
            Keeper keeper1 = new Keeper();
            Keeper keeper2 = new Keeper();

            SushiswapStrategy sushiswapStrategy = new SushiswapStrategy();
            UniswapV2Strategy uniswapV2Strategy = new UniswapV2Strategy();

            Liquidator liquidator = Liquidator(debtLocker.liquidator());

            Rebalancer rebalancer = new Rebalancer();

            erc20_mint(USDC, 9, address(rebalancer), type(uint256).max);  // Mint "infinite" USDC into rebalancer for simulating arbitrage

            assertEq(wbtc.balanceOf(address(liquidator)), 250 * BTC);
            assertEq(usdc.balanceOf(address(liquidator)), 0);
            assertEq(usdc.balanceOf(address(debtLocker)), 0);
            assertEq(usdc.balanceOf(address(keeper1)),    0);
            assertEq(usdc.balanceOf(address(keeper2)),    0);

            assertEq(globals.getLatestPrice(WBTC),            58_975_92000000);    // $58,975.92/WBTC market price
            assertEq(liquidator.getExpectedAmount(250 * BTC), 14_301_660_600000);  // $57,206.64/WBTC sale price (97% of market price)

            // Perform 10 liquidation swaps from each keeper, simulating arbitrage from the market after each trade
            for (uint256 i; i < 10; ++i) {
                keeper1.strategy_flashBorrowLiquidation(
                    address(sushiswapStrategy), 
                    address(debtLocker.liquidator()), 
                    10 * BTC, 
                    type(uint256).max,
                    WBTC, 
                    WETH, 
                    USDC, 
                    address(keeper1)
                );

                rebalancer.swap(sushiswapStrategy.ROUTER(), 10 * BTC, type(uint256).max, USDC, WETH, WBTC);  // Perform fake arbitrage transaction to get price back up 

                keeper2.strategy_flashBorrowLiquidation(
                    address(uniswapV2Strategy), 
                    address(debtLocker.liquidator()), 
                    15 * BTC, 
                    type(uint256).max,
                    WBTC, 
                    WETH, 
                    USDC, 
                    address(keeper2)
                );

                rebalancer.swap(uniswapV2Strategy.ROUTER(), 15 * BTC, type(uint256).max, USDC, WETH, WBTC);  // Perform fake arbitrage transaction to get price back up 
            }
        }

        /***************************************************************/
        /*** Pool delegate claims funds, triggering BPT burning flow ***/
        /***************************************************************/

        // Before state
        bpt_stakeLockerBal      = bpt.balanceOf(ORTHOGONAL_SL);
        pool_principalOut       = pool.principalOut();
        usdc_liquidityLockerBal = usdc.balanceOf(ORTHOGONAL_LL);

        IStakeLockerLike stakeLocker = IStakeLockerLike(ORTHOGONAL_SL);

        uint256 swapOutAmount = IPoolLibLike(ORTHOGONAL_POOL_LIB).getSwapOutValueLocker(BALANCER_POOL, USDC, ORTHOGONAL_SL);

        uint256[7] memory details = pool.claim(address(loanV2), address(debtLockerFactory));

        uint256 totalBptBurn   = 232_836853552955591713;           // BPTs burned after liquidation
        uint256 totalRecovered = 14_301_660_600000;                // Recovered from liquidation
        uint256 totalShortfall = totalPrincipal - totalRecovered;  // Shortfall from liquidation ($85.6m)

        assertEq(details[0], totalRecovered);
        assertEq(details[1], 0);
        assertEq(details[2], 0);
        assertEq(details[3], 0);
        assertEq(details[4], 0);
        assertEq(details[5], totalRecovered);
        assertEq(details[6], totalShortfall);  // 100m - recovered funds

        assertEq(bpt.balanceOf(ORTHOGONAL_SL),   bpt_stakeLockerBal - totalBptBurn);                         // Max amount of BPTs were burned
        assertEq(pool.principalOut(),            pool_principalOut - totalPrincipal);                        // Principal out reduced by full amount
        assertEq(pool.poolLosses(),              totalShortfall - swapOutAmount);                            // Shortfall from liquidation - BPT recovery (zero before)
        assertEq(stakeLocker.bptLosses(),        totalBptBurn);                                              // BPTs burned (zero before)
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),  usdc_liquidityLockerBal + totalRecovered + swapOutAmount);  // Liquidation recovery + BPT recovery
    }

}
