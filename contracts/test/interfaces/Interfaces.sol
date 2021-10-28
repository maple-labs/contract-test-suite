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

    function getLatestPrice(address asset_) external view returns (uint256 price_);

    function governor() external view returns (address governor_);

    function investorFee() external view returns (uint256 investorFee_);

    function setValidLoanFactory(address loanFactory, bool valid) external;

    function setValidSubFactory(address superFactory, address subFactory, bool valid) external;

    function isValidSubFactory(address superFactory, address subFactory, uint8 type_) external returns (bool isValidSubFactory_);

    function treasuryFee() external view returns (uint256 treasuryFee_);

}

interface IMapleTokenLike {}

interface IMapleTreasuryLike {}

interface IMplRewardsFactoryLike {}

interface IPoolFactoryLike {}

interface IPoolLibLike {

    function getSwapOutValueLocker(address _bPool, address liquidityAsset, address stakeLocker) external view returns (uint256 swapOutValue_);

}

interface IPoolLike {

    function claim(address loan, address dlFactory) external returns (uint256[7] memory claimInfo);

    function debtLockers(address loan, address dlFactory) external returns (address);

    function deposit(uint256 amount_) external;

    function fundLoan(address loan, address debtLockerFactory, uint256 amount) external;

    function interestSum() external view returns (uint256 interestSum_);

    function liquidityCap() external view returns (uint256 liquidityCap_);

    function poolLosses() external view returns (uint256 poolLossess_);

    function principalOut() external view returns (uint256 principalOut_);

    function setLiquidityCap(uint256 liquidityCap_) external;

    function triggerDefault(address loan, address dlFactory) external;

}

interface IPriceOracleLike {}

interface IStakeLockerFactoryLike {}

interface IStakeLockerLike {

    function bptLosses() external view returns (uint256 bptLossess_);
    
}

interface IUniswapV2Router02Like {}
