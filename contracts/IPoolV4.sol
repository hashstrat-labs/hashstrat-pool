// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./PoolLPToken.sol";

/**
*  Pool's functionality required by DAOOperations and DAOFarm
*/

interface IPoolV4 {

    // View functions
    function lpToken() external view returns (PoolLPToken);

    function totalValue() external view returns(uint);
    function riskAssetValue() external view returns(uint);
    function stableAssetValue() external view returns(uint);

    function lpTokensValue (uint lpTokens) external view returns (uint);
    function portfolioValue(address addr) external view returns (uint);

    /**
     * @notice  The fees to withdraw the given amount of LP tokens calcualted as percentage of the outstanding
     *          profit that the user is withdrawing
     * @return fees, in LP tokens, that an account would pay to withdraw 'lpToWithdraw' LP tokens.
     *
     */
    function feesForWithdraw(uint lpToWithdraw, address account) external view returns (uint);

    // Transactional functions
    function deposit(uint amount) external;
    function withdrawLP(uint amount) external;

    // Only Owner functions
    function setFeesPerc(uint feesPerc) external;
    function setSlippageThereshold(uint slippage) external;
    function setStrategy(address strategyAddress) external;
    function setUpkeepInterval(uint upkeepInterval) external;
    function collectFees(uint amount) external;
}