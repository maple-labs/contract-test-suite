// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity 0.8.7;

interface IBFactoryLike {}

interface IBPoolLike {}

interface IChainLinkAggregatorLike {}

interface ILiquidityLockerFactoryLike {}

interface ILoanV1Like {}

interface ILoanFactoryV1Like {

    function createLoan(
        address liquidityAsset,
        address collateralAsset,
        address flFactory,
        address clFactory,
        uint256[5] memory specs,
        address[3] memory calcs
    ) external returns (address);

}

interface IMapleGlobalsLike {

    function governor() external view returns (address);

    function investorFee() external view returns (uint256);

    function setValidLoanFactory(address loanFactory, bool valid) external;

    function setValidSubFactory(address superFactory, address subFactory, bool valid) external;

    function isValidSubFactory(address superFactory, address subFactory, uint8 type_) external returns (bool);

    function treasuryFee() external view returns (uint256);

}

interface IMapleTokenLike {}

interface IMapleTreasuryLike {}

interface IMplRewardsFactoryLike {}

interface IPoolFactoryLike {}

interface IPoolLike {

    function claim(address loan, address dlFactory) external returns (uint256[7] memory claimInfo);

    function fundLoan(address loan, address debtLockerFactory, uint256 amount) external;

    function interestSum() external view returns (uint256);

    function principalOut() external view returns (uint256);

}

interface IPriceOracleLike {}

interface IStakeLockerFactoryLike {}

interface IUniswapV2Router02Like {}
