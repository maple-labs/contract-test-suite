// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

import { IUniswapV2StyleStrategy } from "../../../modules/liquidations/contracts/interfaces/IUniswapV2StyleStrategy.sol";

contract Keeper {

    /************************/
    /*** Direct Functions ***/
    /************************/

    function strategy_flashBorrowLiquidation(
        address strategy_, 
        address lender_, 
        uint256 swapAmount_,
        uint256 maxReturnAmount_,
        uint256 minFundsProfit_,
        address collateralAsset_,
        address middleAsset_,
        address fundsAsset_,
        address profitDestination_
    ) 
        external 
    {
        IUniswapV2StyleStrategy(strategy_).flashBorrowLiquidation(
            lender_, 
            swapAmount_,
            maxReturnAmount_,
            minFundsProfit_,
            collateralAsset_,
            middleAsset_,
            fundsAsset_,
            profitDestination_
        );
    }

    /*********************/
    /*** Try Functions ***/
    /*********************/

    function try_strategy_flashBorrowLiquidation(
        address strategy_, 
        address lender_, 
        uint256 swapAmount_,
        uint256 maxReturnAmount_,
        uint256 minFundsProfit_,
        address collateralAsset_,
        address middleAsset_,
        address fundsAsset_,
        address profitDestination_
    ) 
        external returns (bool ok_) 
    {
        ( ok_, ) = strategy_.call(
            abi.encodeWithSelector(
                IUniswapV2StyleStrategy.flashBorrowLiquidation.selector, 
                lender_, 
                swapAmount_,
                maxReturnAmount_,
                minFundsProfit_,
                collateralAsset_,
                middleAsset_,
                fundsAsset_,
                profitDestination_
            )
        );
    }

}
