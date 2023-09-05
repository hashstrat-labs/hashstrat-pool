/// SPDX-License-Identifier: MIT
pragma solidity 0.8.14;


import { LibERC20 } from "./LibERC20.sol";
import { LibPool } from "./LibPool.sol";


/**
 * @notice The library holding data about the users and user activity.
 */
library LibUserInfo {

    bytes32 constant USERINFO_STORAGE_POSITION = keccak256("facet.userinfo.storage");

    enum UserOperation {
        NONE,
        DEPOSIT,
        WITHDRAWAL
    }

    struct SwapInfo {
        uint256 timestamp;
        string side;
        uint256 feedPrice;
        uint256 bought;
        uint256 sold;
        uint256 depositTokenBalance;
        uint256 investTokenBalance;
    }


    struct UserInfo {
        uint256 timestamp;
        UserOperation operation;
        uint256 amount;
    }

    /**
     * @notice ERC20 storage for the ERC20 facet
     */
    struct Storage {
        uint256 _totalDeposited;
        uint256 _totalWithdrawn;

        mapping(address => uint256) _deposits;
        mapping(address => uint256) _withdrawals;
        mapping(address => UserInfo[]) _userInfos;

        address[] _users;
        mapping(address => bool) _usersMap;
    }
    
    // access userInfo storage via:
    function getStorage() internal pure returns (Storage storage ds) {
        bytes32 position = USERINFO_STORAGE_POSITION;
        assembly {
            ds.slot := position
        }
    }

    function totalDeposited() internal view returns(uint) {
        Storage storage ds = getStorage();
        return ds._totalDeposited;
    }

    function totalWithdrawn() internal view returns(uint) {
        Storage storage ds = getStorage();
        return ds._totalWithdrawn;
    }

    function getUsers() internal view returns (address[] memory) {
        Storage storage ds = getStorage();
        return ds._users;
    }

    function getUserInfos(address account) internal view returns (UserInfo[] memory) {
        Storage storage ds = getStorage();
        return ds._userInfos[account];
    }

    function getDeposits(address account) internal view returns (uint256) {
        Storage storage ds = getStorage();
        return ds._deposits[account];
    }

    function getWithdrawals(address account) internal view returns (uint256) {
        Storage storage ds = getStorage();
        return ds._withdrawals[account];
    }



    function portfolioPercentage(address account) internal view returns (uint256) {

        if (LibERC20.erc20totalSupply() == 0) return 0;

        return
            (10**uint256(LibPool.portfolioPercentageDecimals()) *
                LibERC20.erc20balanceOf(account)) / LibERC20.erc20totalSupply();
    }


    function newDepositInfo(uint assets, address user) internal {
        
        Storage storage ds = getStorage();

        ds._deposits[user] += assets;
        ds._totalDeposited += assets;

        // and record user address (if new user) and deposit infos
        if (!ds._usersMap[user]) {
            ds._usersMap[user] = true;
            ds._users.push(user);
        }

        ds._userInfos[user].push(
            UserInfo({
                timestamp: block.timestamp,
                operation: UserOperation.DEPOSIT,
                amount: assets
            })
        );
    }

    function newWithdrawal(uint assets, address user) internal {

        Storage storage ds = getStorage();

        ds._withdrawals[user] += assets;
        ds._totalWithdrawn += assets;

        ds._userInfos[user].push(
            UserInfo({
                timestamp: block.timestamp,
                operation: UserOperation.WITHDRAWAL,
                amount: assets
            })
        );
    }
    
}

