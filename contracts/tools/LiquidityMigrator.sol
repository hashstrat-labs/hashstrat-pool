
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "../interfaces/IPoolV4.sol";
import "../PoolLPToken.sol";


interface IDaoTokenFarm {
    function getStakedBalance(address account, address lpToken) external view returns (uint);
}


contract LiquidityMigrator is Ownable {

    address constant usdc_address = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant hst_farm_address = 0xF3515ED3E4a93185ea16D11A870Cf6Aa65a41Ec7;

    IERC20Metadata usdc;
    IDaoTokenFarm farm;


    event Minted(uint amount);
    event Burned(uint amount_staked, uint amount_not_staked);
    event Withdrawn(uint amount);
    event Deposited(uint amount);
    event Transferred(uint amount);


    constructor () {
       	usdc = IERC20Metadata(usdc_address);
        farm = IDaoTokenFarm(hst_farm_address);
    }


    function migrate(
        address user,
        address old_pool,
        address new_pool,
        uint lp_staked_amount,
        uint lp_not_staked_amount
        
    ) external onlyOwner {
    
        IPoolV4 oldPool = IPoolV4(old_pool);
        PoolLPToken oldPoolLP = PoolLPToken(oldPool.lpToken());
        require (oldPoolLP.isMinter(address(this)), "Not minter for old_pool lp token");

        uint lp_amount_burned = burn(user, old_pool, lp_staked_amount, lp_not_staked_amount);

        uint lp_amount_minted = mint(old_pool, lp_amount_burned);

        uint usdcAmountWithdrawn = withdrawLP(old_pool, lp_amount_minted);

        uint lpReceived = deposit(new_pool, usdcAmountWithdrawn);

        transfer(new_pool, user, lpReceived);
    }


    function burn(
        address user,
        address old_pool,
        uint lp_staked_amount,
        uint lp_not_staked_amount
    )  internal returns (uint lp_amount_burned) {

        IPoolV4 oldPool = IPoolV4(old_pool);
        PoolLPToken oldPoolLP = PoolLPToken(oldPool.lpToken());
        require (oldPoolLP.isMinter(address(this)), "Not minter for old_pool lp token");

        // if function is passed 0 staked/unstaked amount use the full user staked/unstaked balance
        uint lp_staked = lp_staked_amount > 0 ? lp_staked_amount : farm.getStakedBalance(user, address(oldPoolLP));
        uint lp_not_staked = lp_not_staked_amount > 0 ? lp_not_staked_amount : oldPoolLP.balanceOf(user);

        // 1. Burn old lp tokens
        
        if (lp_staked > 0) {
            uint farmLPBalanceBefore = oldPoolLP.balanceOf(hst_farm_address);
            oldPoolLP.burn(hst_farm_address, lp_staked);

            uint farmLPBalanceAfter = oldPoolLP.balanceOf(hst_farm_address);
            require ((farmLPBalanceBefore - farmLPBalanceAfter) == lp_staked, "Error burning LP tokens staked");

            lp_amount_burned += lp_staked;
        }

        if (lp_not_staked > 0) {
            uint userLPBalanceBefore = oldPoolLP.balanceOf(user);
            oldPoolLP.burn(user, lp_not_staked);

            uint userLPBalanceAfter = oldPoolLP.balanceOf(user);
            require ((userLPBalanceBefore - userLPBalanceAfter) == lp_not_staked, "Error burning LP tokens not staked");

            lp_amount_burned += lp_not_staked;
        }
   
        emit Burned(lp_staked_amount, lp_not_staked);
        require(lp_amount_burned > 0, "Error burning LP tokens");

        return lp_amount_burned;
    }


    function mint (address old_pool, uint amount_to_mint) internal returns (uint lp_amount_minted) {

        // 2. Mint lp tokens from old_pool to here
        IPoolV4 oldPool = IPoolV4(old_pool);
        PoolLPToken oldPoolLP = PoolLPToken(oldPool.lpToken());

        uint minterLPBalanceBefore = oldPoolLP.balanceOf(address(this));
        oldPoolLP.mint(address(this), amount_to_mint);
        uint minterLPBalanceAfter = oldPoolLP.balanceOf(address(this));
        lp_amount_minted = (minterLPBalanceAfter - minterLPBalanceBefore);

        require(lp_amount_minted == amount_to_mint, "Error minting LP tokens");

        emit Minted(lp_amount_minted);

        return lp_amount_minted;
    }


    function deposit(address new_pool, uint amount_to_deposit) internal returns (uint lpReceived) {

        IPoolV4 newPool = IPoolV4(new_pool);
        PoolLPToken newPoolLP = PoolLPToken(newPool.lpToken());

        uint usdcBalanceBeforeDeposit = usdc.balanceOf(address(this));

	    uint lpBalanceBeforeDeposit = newPoolLP.balanceOf(address(this));

	    usdc.approve(address(newPool), amount_to_deposit);
	    newPool.deposit(amount_to_deposit);

	    lpReceived = newPoolLP.balanceOf(address(this)) - lpBalanceBeforeDeposit;
        require(lpReceived > 0, "No LP received after deposit");

	    uint amountDeposited = usdcBalanceBeforeDeposit - usdc.balanceOf(address(this));
        require(amountDeposited > 0, "No USDC deposited in new pool");

        emit Deposited(amountDeposited);
    }


    function withdrawLP(address old_pool, uint lp_to_withdraw) internal returns (uint usdcAmountWithdrawn) {
        IPoolV4 oldPool = IPoolV4(old_pool);
        
        // 3. this contract withdraws funds from 'old_pool'
        uint usdcBalanceBeforeWithdrawFromOldPool = usdc.balanceOf(address(this));
        oldPool.withdrawLP(lp_to_withdraw);
        // uint usdcBalanceAfterWithdrawFromOldPool = usdc.balanceOf(address(this));

        usdcAmountWithdrawn = usdc.balanceOf(address(this)) - usdcBalanceBeforeWithdrawFromOldPool;
        require(usdcAmountWithdrawn > 0, "No USDC amount withdrawn");
        
        emit Withdrawn(usdcAmountWithdrawn);
    }


    function transfer(address new_pool, address user, uint amount_to_transfer) internal {

        IPoolV4 newPool = IPoolV4(new_pool);
        PoolLPToken newPoolLP = PoolLPToken(newPool.lpToken());
 
         // 5. transfer LP to  user
	    uint lpBalanceBeforeTransfer = newPoolLP.balanceOf(user);
	    newPoolLP.transfer(user, amount_to_transfer);

        uint transferred = newPoolLP.balanceOf(user) - lpBalanceBeforeTransfer;

        require(transferred > 0, "No LP transferred to user");
        emit Transferred(transferred);
    }

}