// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { Borrower as BorrowerV3 } from "../../../modules/loan-v3/contracts/test/accounts/Borrower.sol";

import { ILoanFactoryV1Like } from "../interfaces/Interfaces.sol";

contract Borrower is BorrowerV3 {

    // Create V1 Loan
    function loanFactory_createLoan(
        address loanFactory,
        address liquidityAsset,
        address collateralAsset,
        address flFactory,
        address clFactory,
        uint256[5] memory specs,
        address[3] memory calcs
    )
        external returns (address)
    {
        return ILoanFactoryV1Like(loanFactory).createLoan(liquidityAsset, collateralAsset, flFactory, clFactory, specs, calcs);
    }

}
