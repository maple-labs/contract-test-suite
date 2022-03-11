// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IERC20 } from "../../modules/erc20/contracts/interfaces/IERC20.sol";

import { TestUtils } from "../../modules/contract-test-utils/contracts/test.sol";

import { DebtLockerFactory }     from "../../modules/debt-locker-v3/contracts/DebtLockerFactory.sol";
import { DebtLockerInitializer } from "../../modules/debt-locker-v3/contracts/DebtLockerInitializer.sol";
import { MapleLoanFactory }      from "../../modules/loan-v3/contracts/MapleLoanFactory.sol";

import { IDebtLocker as IDebtLockerV2 } from "../../modules/debt-locker-v2/contracts/interfaces/IDebtLocker.sol";
import { IMapleLoan as IMapleLoanV2 }   from "../../modules/loan-v2/contracts/interfaces/IMapleLoan.sol";

import { DebtLocker           as DebtLockerV2 }           from "../../modules/debt-locker-v2/contracts/DebtLocker.sol";
import { MapleLoan            as MapleLoanV2 }            from "../../modules/loan-v2/contracts/MapleLoan.sol";
import { MapleLoanInitializer as MapleLoanInitializerV2 } from "../../modules/loan-v2/contracts/MapleLoanInitializer.sol";

import { IDebtLocker as IDebtLockerV3 } from "../../modules/debt-locker-v3/contracts/interfaces/IDebtLocker.sol";
import { IMapleLoan as IMapleLoanV3 }   from "../../modules/loan-v3/contracts/interfaces/IMapleLoan.sol";

import { DebtLocker           as DebtLockerV3 }           from "../../modules/debt-locker-v3/contracts/DebtLocker.sol";
import { MapleLoan            as MapleLoanV3 }            from "../../modules/loan-v3/contracts/MapleLoan.sol";
import { MapleLoanInitializer as MapleLoanInitializerV3 } from "../../modules/loan-v3/contracts/MapleLoanInitializer.sol";

import { IMapleGlobalsLike, IPoolLike } from "./interfaces/Interfaces.sol";

import { Borrower }       from "./accounts/Borrower.sol";
import { GenericAccount } from "./accounts/GenericAccount.sol";

import { AddressRegistry } from "../AddressRegistry.sol";

contract UpgradeTest is AddressRegistry, TestUtils {

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
    uint256 constant ESTABLISHMENT_FEE =       1_232_876712;

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

    DebtLockerFactory     debtLockerFactory;
    DebtLockerInitializer debtLockerInitializer;
    DebtLockerV2          debtLockerImplementationV2;
    DebtLockerV3          debtLockerImplementationV3;

    MapleLoanFactory       loanFactory;
    MapleLoanInitializerV2 loanInitializerV2;
    MapleLoanInitializerV3 loanInitializerV3;
    MapleLoanV2            loanImplementationV2;
    MapleLoanV3            loanImplementationV3;

    IMapleGlobalsLike globals = IMapleGlobalsLike(MAPLE_GLOBALS);
    IPoolLike         pool    = IPoolLike(ORTHOGONAL_POOL);        // Using deployed Orthogonal Pool

    IERC20 bpt  = IERC20(BALANCER_POOL);
    IERC20 usdc = IERC20(USDC);
    IERC20 wbtc = IERC20(WBTC);

    address debtLocker;
    address loan;

    function setUp() external {

        /*******************************/
        /*** Set up actors and state ***/
        /*******************************/

        start = block.timestamp;

        // Set existing Orthogonal PD as Governor
        vm.store(MAPLE_GLOBALS, bytes32(uint256(1)), bytes32(uint256(uint160(address(this)))));

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
        loanFactory          = new MapleLoanFactory(MAPLE_GLOBALS);
        loanImplementationV2 = new MapleLoanV2();
        loanInitializerV2    = new MapleLoanInitializerV2();

        // Register the new implementations and set default version
        loanFactory.registerImplementation(200, address(loanImplementationV2), address(loanInitializerV2));
        loanFactory.setDefaultVersion(200);

        globals.setValidLoanFactory(address(loanFactory), true);  // Whitelist new LoanFactory

        /***********************************************/
        /*** Deploy and set up new DebtLockerFactory ***/
        /***********************************************/

        // Deploy new LoanFactory, implementation, and initializer
        debtLockerFactory          = new DebtLockerFactory(MAPLE_GLOBALS);
        debtLockerImplementationV2 = new DebtLockerV2();
        debtLockerInitializer      = new DebtLockerInitializer();

        // Register the new implementations and set default version
        debtLockerFactory.registerImplementation(200, address(debtLockerImplementationV2), address(debtLockerInitializer));
        debtLockerFactory.setDefaultVersion(200);

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

        bytes memory arguments = loanInitializerV2.encodeArguments(address(borrower), assets, termDetails, requests, rates);

        bytes32 salt = keccak256(abi.encodePacked("salt"));

        loan = borrower.mapleProxyFactory_createInstance(address(loanFactory), arguments, salt);
    }

    function test_loanUpgrades() external {

        /********************/
        /*** Upgrade Loan ***/
        /********************/

        // Deploying and registering a new version.
        loanImplementationV3 = new MapleLoanV3();
        loanInitializerV3    = new MapleLoanInitializerV3();

        loanFactory.registerImplementation(300, address(loanImplementationV3), address(loanInitializerV3));
        loanFactory.enableUpgradePath(200, 300, address(0));

        assertEq(IMapleLoanV2(loan).implementation(), address(loanImplementationV2));
        assertEq(IMapleLoanV2(loan).factory(),        address(loanFactory));

        // Not borrower can't migrate
        try notBorrower.loan_upgrade(loan, 300, "") { assertTrue(false, "Non-borrower could upgrade"); } catch { }

        // Nothing changes
        assertEq(IMapleLoanV2(loan).implementation(), address(loanImplementationV2));
        assertEq(IMapleLoanV2(loan).factory(),        address(loanFactory));

        borrower.loan_upgrade(loan, 300, "");

        assertEq(IMapleLoanV3(loan).implementation(), address(loanImplementationV3));
        assertEq(IMapleLoanV3(loan).factory(),        address(loanFactory));
    }

    function test_debtLockerUpgrades() external {

        /*****************/
        /*** Fund Loan ***/
        /*****************/

        uint256 fundAmount = 1_000_000 * USD;

        assertEq(pool_principalOut       = pool.principalOut(),            PRINCIPAL_OUT);
        assertEq(pool_interestSum        = pool.interestSum(),             INTEREST_SUM);
        assertEq(usdc_liquidityLockerBal = usdc.balanceOf(ORTHOGONAL_LL),  LL_USDC_BAL);
        assertEq(usdc_stakeLockerBal     = usdc.balanceOf(ORTHOGONAL_SL),  SL_USDC_BAL);
        assertEq(usdc_poolDelegateBal    = usdc.balanceOf(ORTHOGONAL_PD),  PD_USDC_BAL);
        assertEq(usdc_treasuryBal        = usdc.balanceOf(MAPLE_TREASURY), TREASURY_USDC_BAL);

        assertEq(usdc.balanceOf(address(loan)), 0);

        pool.fundLoan(loan, address(debtLockerFactory), fundAmount);

        assertEq(pool.principalOut(),             pool_principalOut       += fundAmount);
        assertEq(pool.interestSum(),              pool_interestSum        += 0);
        assertEq(usdc.balanceOf(ORTHOGONAL_LL),   usdc_liquidityLockerBal -= fundAmount);
        assertEq(usdc.balanceOf(ORTHOGONAL_SL),   usdc_stakeLockerBal     += 0);
        assertEq(usdc.balanceOf(ORTHOGONAL_PD),   usdc_poolDelegateBal    += ESTABLISHMENT_FEE / 2);  // Investor estab fee
        assertEq(usdc.balanceOf(MAPLE_TREASURY),  usdc_treasuryBal        += ESTABLISHMENT_FEE / 2);  // Treasury estab fee

        assertEq(usdc.balanceOf(address(loan)), fundAmount - ESTABLISHMENT_FEE);  // Remaining funds

        /***************************/
        /*** Upgrade Debt Locker ***/
        /***************************/

        // Deploying and registering a new version
        debtLockerImplementationV3 = new DebtLockerV3();
        debtLockerFactory.registerImplementation(300, address(debtLockerImplementationV3), address(debtLockerInitializer));
        debtLockerFactory.enableUpgradePath(200, 300, address(0));

        debtLocker = IMapleLoanV2(loan).lender();

        assertEq(IDebtLockerV2(debtLocker).implementation(), address(debtLockerImplementationV2));
        assertEq(IDebtLockerV2(debtLocker).factory(),        address(debtLockerFactory));

        // Not Governor can't update
        GenericAccount account = new GenericAccount();

        try account.call(debtLocker, abi.encodeWithSelector(DebtLockerV2.upgrade.selector, 300, "")) {
            assertTrue(false, "Generic account could upgrade");
        } catch { }

        assertEq(IDebtLockerV2(debtLocker).implementation(), address(debtLockerImplementationV2));
        assertEq(IDebtLockerV2(debtLocker).factory(),        address(debtLockerFactory));

        // address(this) is PoolDelegate
        IDebtLockerV2(debtLocker).upgrade(300, "");

        assertEq(IDebtLockerV3(debtLocker).implementation(), address(debtLockerImplementationV3));
        assertEq(IDebtLockerV3(debtLocker).factory(),        address(debtLockerFactory));
    }

}
